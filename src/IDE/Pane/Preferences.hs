{-# LANGUAGE CPP #-}
{-# OPTIONS_GHC -XScopedTypeVariables -XDeriveDataTypeable -XMultiParamTypeClasses
    -XTypeSynonymInstances #-}
-----------------------------------------------------------------------------
--
-- Module      :  IDE.Pane.Preferences
-- Copyright   :  (c) Juergen Nicklisch-Franken, Hamish Mackenzie
-- License     :  GNU-GPL
--
-- Maintainer  :  <maintainer at leksah.org>
-- Stability   :  provisional
-- Portability :  portable
--
--
-- | Module for saving, restoring and editing preferences
--
---------------------------------------------------------------------------------


module IDE.Pane.Preferences (
    IDEPrefs(..)
,   PrefsState
,   readPrefs
,   writePrefs
,   defaultPrefs
,   prefsDescription
,   editPrefs
) where

import Graphics.UI.Gtk hiding(background)
import Control.Monad.Reader
import qualified Text.ParserCombinators.Parsec as P
import Data.List
import qualified Text.PrettyPrint.HughesPJ as PP
import Distribution.Package
import Data.IORef
import Data.Typeable

import Control.Event
import Graphics.UI.Editor.Basics
import IDE.Core.State
import Graphics.UI.Editor.Simple
import Graphics.UI.Editor.Composite
import Graphics.UI.Editor.Parameters
import Graphics.UI.Editor.MakeEditor hiding (parameters)
import IDE.DescriptionPP
import IDE.PrinterParser hiding (fieldParser,parameters)
import IDE.TextEditor
import IDE.Pane.SourceBuffer
import IDE.Pane.Log
import Default
import IDE.FileUtils
import System.IO
import Distribution.InstalledPackageInfo (package)
import IDE.Metainfo.GHCUtils (getInstalledPackageInfos,inGhc)
import Packages (PackageConfig(..))
import IDE.Debug
    (debugSetPrintBindResult,
     debugSetBreakOnError,
     debugSetBreakOnException,
     debugSetPrintEvldWithShow)
import Graphics.UI.Gtk.SourceView
    (sourceStyleSchemeManagerGetSchemeIds, sourceStyleSchemeManagerNew)

--
-- | The Preferences Pane
--

data IDEPrefs               =   IDEPrefs {
    prefsBox                ::   VBox
} deriving Typeable

data PrefsState             =   PrefsState
    deriving(Eq,Ord,Read,Show,Typeable)

instance IDEObject IDEPrefs

instance Pane IDEPrefs IDEM
    where
    primPaneName _  =   "Prefs"
    getAddedIndex _ =   0
    getTopWidget    =   castToWidget . prefsBox
    paneId b        =   "*Prefs"
    makeActive prefs =  activatePane prefs []
    close           =   closePane

instance RecoverablePane IDEPrefs PrefsState IDEM where
    saveState p     =   return Nothing
    recoverState pp st  =  return ()

-- ------------------------------------------------------------
-- * Editing
-- ------------------------------------------------------------

editPrefs :: IDEAction
editPrefs = do
    getPrefs
    return ()

getPrefs :: IDEM IDEPrefs
getPrefs = do
    mbPrefs <- getPane
    case mbPrefs of
        Nothing -> do
            pp  <- getBestPathForId "*Prefs"
            nb          <-  getNotebook pp
            initPrefs pp nb
            mbPrefs <- getPane
            case mbPrefs of
                Nothing ->  throwIDE "Can't init prefs pane"
                Just m  ->  do
                        liftIO $bringPaneToFront m
                        return m
        Just m ->   do
            liftIO $bringPaneToFront m
            return m

initPrefs :: PanePath -> Notebook -> IDEAction
initPrefs panePath nb2 = do
    packageInfos <- inGhc getInstalledPackageInfos
    let flatPrefsDesc = flattenFieldDescriptionPP (prefsDescription (map package packageInfos))
    prefs       <-  readIDE prefs
    lastAppliedPrefsRef <- liftIO $ newIORef prefs
    currentInfo <-  readIDE currentInfo
    newPane panePath nb2 (builder lastAppliedPrefsRef packageInfos flatPrefsDesc prefs)
    return ()

builder :: IORef Prefs ->
    [PackageConfig] ->
    [FieldDescriptionPP Prefs] ->
    Prefs ->
    PanePath ->
    Notebook ->
    Window ->
    IDERef ->
    IO (IDEPrefs,Connections)
builder lastAppliedPrefsRef packageInfos flatPrefsDesc prefs pp nb windows ideR = do
    vb      <-  vBoxNew False 0
    bb      <-  hButtonBoxNew
    apply   <-  buttonNewFromStock "gtk-apply"
    restore <-  buttonNewFromStock "Restore"
    save    <-  buttonNewFromStock "gtk-save"
    closeB  <-  buttonNewFromStock "gtk-close"
    boxPackStart bb apply PackNatural 0
    boxPackStart bb restore PackNatural 0
    boxPackStart bb save PackNatural 0
    boxPackStart bb closeB PackNatural 0
    (widget,injb,ext,notifier) <-  buildEditor (extractFieldDescription $ prefsDescription (map package packageInfos)) prefs
    boxPackStart vb widget PackGrow 7
    boxPackEnd vb bb PackNatural 7
    let prefsPane = IDEPrefs vb
    apply `onClicked` (do
        mbNewPrefs <- extract prefs [ext]
        case mbNewPrefs of
            Nothing -> return ()
            Just newPrefs -> do
                lastAppliedPrefs    <- readIORef lastAppliedPrefsRef
                mapM_ (\ (FDPP _ _ _ _ applyF) -> reflectIDE (applyF newPrefs lastAppliedPrefs) ideR ) flatPrefsDesc
                writeIORef lastAppliedPrefsRef newPrefs)
    restore `onClicked` (do
        lastAppliedPrefs <- readIORef lastAppliedPrefsRef
        mapM_ (\ (FDPP _ _ _ _ applyF) -> reflectIDE (applyF prefs lastAppliedPrefs) ideR ) flatPrefsDesc
        injb prefs
        writeIORef lastAppliedPrefsRef prefs)
    save `onClicked` (do
        lastAppliedPrefs <- readIORef lastAppliedPrefsRef
        mbNewPrefs <- extract prefs [ext]
        case mbNewPrefs of
            Nothing -> return ()
            Just newPrefs -> do
            mapM_ (\ (FDPP _ _ _ _ applyF) -> reflectIDE (applyF newPrefs lastAppliedPrefs) ideR ) flatPrefsDesc
            fp <- getConfigFilePathForSave "Default.prefs"
            writePrefs fp newPrefs
            reflectIDE (modifyIDE_ (\ide -> ide{prefs = newPrefs})) ideR )
    closeB `onClicked` (reflectIDE (close prefsPane >> return ()) ideR )
    registerEvent notifier FocusIn (Left (\e -> do
        reflectIDE (makeActive prefsPane) ideR
        return (e{gtkReturn=False})))
    return (prefsPane,[])


-- ------------------------------------------------------------
-- * Dialog definition
-- ------------------------------------------------------------

prefsDescription :: [PackageIdentifier] -> FieldDescriptionPP Prefs
prefsDescription packages = NFDPP [
    ("Editor", VFDPP emptyParams [
        mkFieldPP
            (paraName <<<- ParaName "Show line numbers"
                $ paraSynopsis <<<- ParaSynopsis "(True/False)" $ emptyParams)
            (PP.text . show)
            boolParser
            showLineNumbers
            (\ b a -> a{showLineNumbers = b})
            boolEditor
            (\b -> do
                buffers <- allBuffers
                mapM_ (\buf -> liftIO $ setShowLineNumbers (sourceView buf) b) buffers)
    ,   mkFieldPP
            (paraName <<<- ParaName "TextView Font" $ emptyParams)
            (\a -> PP.text (case a of Nothing -> show ""; Just s -> show s))
            (do str <- stringParser
                return (if null str then Nothing else Just (str)))
            textviewFont
            (\ b a -> a{textviewFont = b})
            fontEditor
            (\mbs -> do
                buffers <- allBuffers
                liftIO $mapM_ (\buf -> setFont (sourceView buf) mbs) buffers)
    ,   mkFieldPP
            (paraName <<<- ParaName "Right margin"
                $ paraSynopsis <<<- ParaSynopsis "Size or 0 for no right margin"
                    $ paraShadow <<<- ParaShadow ShadowIn $ emptyParams)
            (\a -> (PP.text . show) (case a of Nothing -> 0; Just i -> i))
            (do i <- intParser
                return (if i == 0 then Nothing else Just i))
            rightMargin
            (\b a -> a{rightMargin = b})
            (maybeEditor (intEditor (1.0, 200.0, 5.0), paraName <<<- ParaName "Position"
                    $ emptyParams)
                    True "Show it ?")
            (\b -> do
                buffers <- allBuffers
                mapM_ (\buf -> liftIO $ setRightMargin (sourceView buf) b) buffers)
    ,   mkFieldPP
            (paraName <<<- ParaName "Tab width" $ emptyParams)
            (PP.text . show)
            intParser
            tabWidth
            (\b a -> a{tabWidth = b})
            (intEditor (1.0, 20.0, 1.0))
            (\i -> do
                buffers <- allBuffers
                mapM_ (\buf -> liftIO $setIndentWidth (sourceView buf) i) buffers)
    ,   mkFieldPP
            (paraName <<<- ParaName "Use standard line ends even on windows" $ emptyParams)
            (PP.text . show)
            boolParser
            forceLineEnds
            (\b a -> a{forceLineEnds = b})
            boolEditor
            (\i -> return ())
    ,   mkFieldPP
            (paraName <<<- ParaName "Remove trailing blanks when saving a file" $ emptyParams)
            (PP.text . show)
            boolParser
            removeTBlanks
            (\b a -> a{removeTBlanks = b})
            boolEditor
            (\i -> return ())
    ,   mkFieldPP
            (paraName <<<- ParaName "Source candy"
                $ paraSynopsis <<<- ParaSynopsis
                    "Empty for do not use or the name of a candy file in a config dir"
                    $ paraShadow <<<- ParaShadow ShadowIn $ emptyParams)
            (\a -> PP.text (case a of Nothing -> show ""; Just s -> show s))
            (do str <- stringParser
                return (if null str then Nothing else Just (str)))
            sourceCandy (\b a -> a{sourceCandy = b})
            (maybeEditor ((stringEditor (\s -> not (null s))), paraName <<<- ParaName "Candy specification"
                                    $ emptyParams)
                    True "Use it ?")
            (\cs -> case cs of
                        Nothing -> do
                            setCandyState False
                            editCandy
                        Just name -> do
                            setCandyState True
                            editCandy)
    ,   mkFieldPP
            (paraName <<<- ParaName "Editor Style" $ emptyParams)
            (\a -> PP.text (case a of Nothing -> show ""; Just s -> show s))
            (do str <- stringParser
                return (if null str then Nothing else Just (str)))
            sourceStyle
            (\b a -> a{sourceStyle = b})
            styleEditor
            (\mbs -> do
                buffers <- allBuffers
                mapM_ (\buf -> liftIO $ do
                    ebuf <- getBuffer (sourceView buf)
                    setStyle ebuf mbs) buffers)
    ,   mkFieldPP
            (paraName <<<- ParaName "Found Text Background" $ emptyParams)
            (PP.text . show)
            colorParser
            foundBackground
            (\ b a -> a{foundBackground = b})
            colorEditor
            (\c -> do
                buffers <- allBuffers
                liftIO $ forM_ buffers $ \buf -> do
                    ebuf     <- getBuffer (sourceView buf)
                    tagTable <- getTagTable ebuf
                    mbTag    <- lookupTag tagTable "found"
                    case mbTag of
                        Just tag -> background tag c
                        Nothing  -> return ())
    ,   mkFieldPP
            (paraName <<<- ParaName "Execution Context Text Background" $ emptyParams)
            (PP.text . show)
            colorParser
            contextBackground
            (\ b a -> a{contextBackground = b})
            colorEditor
            (\c -> do
                buffers <- allBuffers
                liftIO $ forM_ buffers $ \buf -> do
                    ebuf     <- getBuffer (sourceView buf)
                    tagTable <- getTagTable ebuf
                    --  TODO find and set the tag background
                    return ())
    ,   mkFieldPP
            (paraName <<<- ParaName "Breakpoint Text Background" $ emptyParams)
            (PP.text . show)
            colorParser
            breakpointBackground
            (\ b a -> a{breakpointBackground = b})
            colorEditor
            (\c -> do
                buffers <- allBuffers
                liftIO $ forM_ buffers $ \buf -> do
                    ebuf     <- getBuffer (sourceView buf)
                    tagTable <- getTagTable ebuf
                    --  TODO find and set the tag background
                    return ())
    ]),
    ("GUI Options", VFDPP emptyParams [
        mkFieldPP
            (paraName <<<- ParaName "LogView Font" $ emptyParams)
            (\a -> PP.text (case a of Nothing -> show ""; Just s -> show s))
            (do str <- stringParser
                return (if null str then Nothing else Just (str)))
            logviewFont
            (\ b a -> a{logviewFont = b})
            fontEditor
            (\mbs -> do
                buffer <- getLog
                fdesc <- liftIO $fontDescriptionFromString (case mbs of Just str -> str; Nothing -> "")
                liftIO $widgetModifyFont (castToWidget $textView buffer) (Just fdesc))
    ,   mkFieldPP
            (paraName <<<- ParaName "Window default size"
                $ paraSynopsis <<<- ParaSynopsis
                    "Default size of the main ide window specified as pair (int,int)"
                    $ paraShadow <<<- ParaShadow ShadowIn $ emptyParams)
            (PP.text.show)
            (pairParser intParser)
            defaultSize (\(c,d) a -> a{defaultSize = (c,d)})
            (pairEditor ((intEditor (0.0, 3000.0, 25.0)),
                            paraName <<<- ParaName "X" $ emptyParams)
                        ((intEditor (0.0, 3000.0, 25.0)),
                            paraName <<<- ParaName "Y" $ emptyParams))
            (\a -> return ())
    ,   mkFieldPP
            (paraName <<<- ParaName "Use ctrl Tab for Notebook flipper" $ emptyParams)
            (PP.text . show)
            boolParser
            useCtrlTabFlipping
            (\b a -> a{useCtrlTabFlipping = b})
            boolEditor
            (\i -> return ())
    ,   mkFieldPP
            (paraName <<<- ParaName "Complete only on Hotkey" $ emptyParams)
            (PP.text . show)
            boolParser
            completeRestricted
            (\b a -> a{completeRestricted = b})
            boolEditor
            (\i -> return ())
    ,   mkFieldPP
            (paraName <<<- ParaName "Name of the keymap"
                $ paraSynopsis <<<- ParaSynopsis
                    "The name of a keymap file in a config dir"
                    $ paraDirection <<<- ParaDirection Horizontal $ emptyParams)
            PP.text
            identifier
            keymapName
            (\b a -> a{keymapName = b})
            (stringEditor (\s -> not (null s)))
            (\ a -> return ())
    ]),
    ("Initial Pane positions", VFDPP emptyParams [
        mkFieldPP
            (paraName <<<- ParaName
                "Categories for panes"
                $ paraShadow <<<- ParaShadow ShadowIn
                     $ paraDirection <<<- ParaDirection Vertical $ emptyParams)
            (PP.text . show)
            readParser
            categoryForPane
            (\b a -> a{categoryForPane = b})
            (multisetEditor
                (ColumnDescr True [("Pane Id",\(n,_) -> [cellText := n])
                                   ,("Pane Category",\(_,v) -> [cellText := v])])
                ((pairEditor
                    (stringEditor (\s -> not (null s)),emptyParams)
                    (stringEditor (\s -> not (null s)),emptyParams)),emptyParams)
            Nothing
            Nothing)
            (\i -> return ())
    ,   mkFieldPP
            (paraName <<<- ParaName
                "Pane path for category"
                $ paraShadow <<<- ParaShadow ShadowIn
                     $ paraDirection <<<- ParaDirection Vertical $ emptyParams)
            (PP.text . show)
            readParser
            pathForCategory
            (\b a -> a{pathForCategory = b})
            (multisetEditor
                (ColumnDescr True [("Pane category",\(n,_) -> [cellText := n])
                                   ,("Pane path",\(_,v) -> [cellText := show v])])
                ((pairEditor
                    (stringEditor (\s -> not (null s)),emptyParams)
                    (genericEditor,emptyParams)),emptyParams)
            Nothing
            Nothing)
            (\i -> return ())
    ,   mkFieldPP
            (paraName <<<- ParaName "Default pane path" $ emptyParams)
            (PP.text . show)
            readParser
            defaultPath
            (\b a -> a{defaultPath = b})
            genericEditor
            (\i -> return ())
    ]),
    ("Metadata", VFDPP emptyParams [
        mkFieldPP
            (paraName <<<- ParaName
                "Paths under which haskell sources for packages may be found" $ emptyParams)
            (PP.text . show)
            readParser
            sourceDirectories
            (\b a -> a{sourceDirectories = b})
            (filesEditor Nothing FileChooserActionSelectFolder "Select folder")
            (\i -> return ())
    ,   mkFieldPP
            (paraName <<<- ParaName "Extract packages from cabal-install" $ emptyParams)
            (PP.text . show)
            readParser
            autoExtractTars
            (\b a -> a{autoExtractTars = b})
            (maybeEditor ((fileEditor (Just "~/.cabal/packages/") FileChooserActionSelectFolder
                "Select folder"), emptyParams) True "Yes")
            (\i -> return ())
    ,   mkFieldPP
            (paraName <<<- ParaName "Update metadata at startup" $ emptyParams)
            (PP.text . show)
            boolParser
            collectAtStart
            (\b a -> a{collectAtStart = b})
            boolEditor
            (\i -> return ())
    ,   mkFieldPP
            (paraName <<<- ParaName "Update metadata after every build" $ emptyParams)
            (PP.text . show)
            boolParser
            collectAfterBuild
            (\b a -> a{collectAfterBuild = b})
            boolEditor
            (\i -> return ())
    ]),
    ("Blacklist", VFDPP emptyParams [
        mkFieldPP
            (paraName <<<- ParaName
                "Packages which are excluded from the modules pane" $ emptyParams)
            (PP.text . show)
            readParser
            packageBlacklist
            (\b a -> a{packageBlacklist = b})
            (dependenciesEditor packages)
            (\i -> return ())
    ]),
    ("Build", VFDPP emptyParams [
         mkFieldPP
            (paraName <<<- ParaName "Automatically save all files before building" $ emptyParams)
            (PP.text . show)
            boolParser
            saveAllBeforeBuild
            (\b a -> a{saveAllBeforeBuild = b})
            boolEditor
            (\i -> return ())
         , mkFieldPP
            (paraName <<<- ParaName "Background build" $ emptyParams)
            (PP.text . show)
            boolParser
            backgroundBuild
            (\b a -> a{backgroundBuild = b})
            boolEditor
            (\i -> return ())
         , mkFieldPP
            (paraName <<<- ParaName "Include linking in background builds" $ emptyParams)
            (PP.text . show)
            boolParser
            backgroundLink
            (\b a -> a{backgroundLink = b})
            boolEditor
            (\i -> return ())
    ]),
    ("Debug", VFDPP emptyParams [
           mkFieldPP
            (paraName <<<- ParaName "Enable usage of Show instances in :print" $ emptyParams)
            (PP.text . show)
            boolParser
            printEvldWithShow
            (\b a -> a{printEvldWithShow = b})
            boolEditor
            debugSetPrintEvldWithShow
         , mkFieldPP
            (paraName <<<- ParaName "Break on any exception thrown" $ emptyParams)
            (PP.text . show)
            boolParser
            breakOnException
            (\b a -> a{breakOnException = b})
            boolEditor
            debugSetBreakOnException
         , mkFieldPP
            (paraName <<<- ParaName "Break on uncaught exceptions and errors" $ emptyParams)
            (PP.text . show)
            boolParser
            breakOnError
            (\b a -> a{breakOnError = b})
            boolEditor
            debugSetBreakOnError
         , mkFieldPP
            (paraName <<<- ParaName "Turn on printing of binding results in GHCi" $ emptyParams)
            (PP.text . show)
            boolParser
            printBindResult
            (\b a -> a{printBindResult = b})
            boolEditor
            debugSetPrintBindResult
    ]),
    ("Help", VFDPP emptyParams [
        mkFieldPP
            (paraName <<<- ParaName "Browser" $ emptyParams)
            (PP.text . show)
            stringParser
            browser
            (\b a -> a{browser = b})
            (stringEditor (\s -> not (null s)))
            (\i -> return ())
    ,   mkFieldPP
            (paraName <<<- ParaName "URL for searching documentation" $
                paraSynopsis <<<- ParaSynopsis
                    ("e.g Hoogle: http://www.haskell.org/hoogle/?q= or " ++
                        "Hayoo: http://holumbus.fh-wedel.de/hayoo/hayoo.html?query=")
                        $ emptyParams)
            (PP.text . show)
            stringParser
            docuSearchURL
            (\b a -> a{docuSearchURL = b})
            (stringEditor (\s -> not (null s)))
            (\i -> return ())
    ])]


styleEditor :: Editor (Maybe String)
styleEditor p n = do
    styleManager <- sourceStyleSchemeManagerNew
    ids          <- sourceStyleSchemeManagerGetSchemeIds styleManager
    maybeEditor (comboSelectionEditor ids id, p) True "Select a special style?" p n


instance Default PackageIdentifier where
    getDefault = case toPackageIdentifier "unknown-0" of
                    Nothing -> throwIDE "Preferences.getDefault: Can't parse Package Identifier"
                    Just it -> it

defaultPrefs = Prefs {
        showLineNumbers     =   True
    ,   rightMargin         =   Just 100
    ,   tabWidth            =   4
    ,   sourceCandy         =   Just("Default")
    ,   keymapName          =   "Default"
    ,   forceLineEnds       =   True
    ,   removeTBlanks       =   True
    ,   textviewFont        =   Nothing
    ,   sourceStyle         =   Nothing
    ,   foundBackground     =   Color 65535 65535 32768
    ,   contextBackground   =   Color 65535 49152 49152
    ,   breakpointBackground =  Color 65535 49152 32768
    ,   logviewFont         =   Nothing
    ,   defaultSize         =   (1024,800)
    ,   browser             =   "firefox"
    ,   sourceDirectories   =   []
    ,   packageBlacklist    =   []
    ,   pathForCategory     =   [   ("EditorCategory",[SplitP (LeftP)])
                                ,   ("TreeCategory",[SplitP (RightP),SplitP (TopP)])
                                ,   ("LogCategory",[SplitP (RightP), SplitP (BottomP)])
                                ,   ("DialogCategory",[SplitP (RightP),SplitP (TopP)])]
    ,   defaultPath         =   [SplitP (LeftP)]
    ,   categoryForPane     =   [   ("*ClassHierarchy","TreeCategory")
                                ,   ("*Debug","TreeCategory")
                                ,   ("*Grep","TreeCategory")
                                ,   ("*Info","LogCategory")
                                ,   ("*Log","LogCategory")
                                ,   ("*Modules","TreeCategory")
                                ,   ("*Package","DialogCategory")
                                ,   ("*Flags","DialogCategory")
                                ,   ("*Prefs","DialogCategory")
                                ,   ("*References","LogCategory")
                                ,   ("*Search","TreeCategory")]
    ,   collectAfterBuild   =   False
    ,   collectAtStart      =   True
    ,   autoExtractTars     =   Nothing
    ,   useCtrlTabFlipping  =   True
    ,   docuSearchURL       =   "http://holumbus.fh-wedel.de/hayoo/hayoo.html?query="
    ,   completeRestricted  =   False
    ,   saveAllBeforeBuild  =   True
    ,   backgroundBuild     =   True
    ,   backgroundLink      =
#if defined(mingw32_HOST_OS) || defined(__MINGW32__)
                                False
#else
                                True
#endif
    ,   printEvldWithShow   =   True
    ,   breakOnException    =   True
    ,   breakOnError        =   True
    ,   printBindResult     =   False
    }

-- ------------------------------------------------------------
-- * Parsing
-- ------------------------------------------------------------

readPrefs :: FilePath -> IO Prefs
readPrefs fn = catch (do
    res <- P.parseFromFile (prefsParser defaultPrefs (flattenFieldDescriptionPP
                    (prefsDescription []))) fn
    case res of
                Left pe -> throwIDE $ "Error reading prefs file " ++ show fn ++ " " ++ show pe
                Right r -> return r)
    (\ e -> throwIDE $ "Error reading prefs file " ++ show fn ++ " " ++ show e)

prefsParser ::  a ->  [FieldDescriptionPP a] ->  P.CharParser () a
prefsParser def descriptions =
    let parsersF = map fieldParser descriptions in do
        res <-  applyFieldParsers def parsersF
        return res
        P.<?> "prefs parser"

-- ------------------------------------------------------------
-- * Printing
-- ------------------------------------------------------------

writePrefs :: FilePath -> Prefs -> IO ()
writePrefs fpath prefs = writeFile fpath (showPrefs prefs (flattenFieldDescriptionPP (prefsDescription [])))

showPrefs ::  a ->  [FieldDescriptionPP a] ->  String
showPrefs prefs prefsDesc = PP.render $
    foldl (\ doc (FDPP _ printer _ _ _) ->  doc PP.$+$ printer prefs) PP.empty prefsDesc

