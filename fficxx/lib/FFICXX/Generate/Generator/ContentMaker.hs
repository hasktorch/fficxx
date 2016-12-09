{-# LANGUAGE GADTs #-}

-----------------------------------------------------------------------------
-- |
-- Module      : FFICXX.Generate.Generator.ContentMaker
-- Copyright   : (c) 2011-2013,2015,2016 Ian-Woo Kim
--
-- License     : BSD3
-- Maintainer  : Ian-Woo Kim <ianwookim@gmail.com>
-- Stability   : experimental
-- Portability : GHC
--
-----------------------------------------------------------------------------

module FFICXX.Generate.Generator.ContentMaker where 

import           Control.Applicative
import           Control.Lens (set,at)
import           Control.Monad.Trans.Reader
import           Data.Function (on)
import qualified Data.Map as M
import           Data.List 
import           Data.List.Split (splitOn) 
import           Data.Maybe
import           System.FilePath 
import           Text.StringTemplate hiding (render)
-- 
import           FFICXX.Generate.Code.Cpp
import           FFICXX.Generate.Code.HsFFI 
import           FFICXX.Generate.Code.HsFrontEnd
import           FFICXX.Generate.Type.Annotate
import           FFICXX.Generate.Type.Class
import qualified FFICXX.Generate.Type.PackageInterface as T
import           FFICXX.Generate.Util
--

srcDir :: FilePath -> FilePath
srcDir installbasedir = installbasedir </> "src" 

csrcDir :: FilePath -> FilePath
csrcDir installbasedir = installbasedir </> "csrc" 

pkgModuleTemplate :: String
pkgModuleTemplate = "Pkg.hs"

moduleTemplate :: String 
moduleTemplate = "module.hs"

hsbootTemplate :: String
hsbootTemplate = "Class.hs-boot"

declarationTemplate :: String
declarationTemplate = "Module.h"

typeDeclHeaderFileName :: String
typeDeclHeaderFileName = "PkgType.h"

definitionTemplate :: String
definitionTemplate = "Pkg.cpp"

rawtypeHsFileName :: String
rawtypeHsFileName = "RawType.hs"

ffiHscFileName :: String 
ffiHscFileName = "FFI.hsc"

interfaceHsFileName :: String
interfaceHsFileName = "Interface.hs"

castHsFileName :: String
castHsFileName = "Cast.hs"

implementationHsFileName :: String 
implementationHsFileName = "Implementation.hs"

existentialHsFileName :: String 
existentialHsFileName = "Existential.hs"


---- common function for daughter


-- | 
mkGlobal :: [Class] -> ClassGlobal
mkGlobal = ClassGlobal <$> mkDaughterSelfMap <*> mkDaughterMap 


-- | 
mkDaughterDef :: ((String,[Class]) -> String) 
              -> DaughterMap 
              -> String 
mkDaughterDef f m =   
    let lst = M.toList m 
        f' (x,xs) =  f (x,filter (not.isAbstractClass) xs) 
    in (concatMap f' lst)

-- | 
mkParentDef :: ((Class,Class)->String) -> Class -> String
mkParentDef f cls = g (class_allparents cls,cls)
  where g (ps,c) = concatMap (\p -> f (p,c)) ps

-- | 
mkProtectedFunctionList :: Class -> String 
mkProtectedFunctionList c = 
    (unlines 
     . map (\x->"#define IS_" ++ class_name c ++ "_" ++ x ++ "_PROTECTED ()") 
     . unProtected . class_protected) c 

-- |
mkTypeDeclHeader :: STGroup String
                 -> T.TypeMacro -- ^ typemacro 
                 -> [Class]
                 -> String 
mkTypeDeclHeader templates (T.TypMcro typemacro) classes =
  let typeDeclBodyStr   = genAllCppHeaderTmplType classes 
  in  renderTemplateGroup 
        templates 
        [ ("typeDeclBody", typeDeclBodyStr ) 
        , ("typemacro", typemacro ) 

        ] 
        typeDeclHeaderFileName

-- | 
mkDeclHeader :: STGroup String 
             -> T.TypeMacro  -- ^ typemacro prefix 
             -> String     -- ^ C prefix 
             -> ClassImportHeader 
             -> String 
mkDeclHeader templates (T.TypMcro typemacroprefix) cprefix header =
  let classes = [cihClass header]
      aclass = cihClass header
      typemacrostr = typemacroprefix ++ class_name aclass ++ "__" 
      declHeaderStr = intercalateWith connRet (\x->"#include \""++x++"\"") $
                        map T.unHdrName (cihIncludedHPkgHeadersInH header)
      declDefStr    = genAllCppHeaderTmplVirtual classes 
                      `connRet2`
                      genAllCppHeaderTmplNonVirtual classes 
                      `connRet2`   
                      genAllCppDefTmplVirtual classes
                      `connRet2`
                       genAllCppDefTmplNonVirtual classes
      classDeclsStr = if (fst.hsClassName) aclass /= "Deletable"
                        then mkParentDef genCppHeaderInstVirtual aclass 
                             `connRet2`
                             genCppHeaderInstVirtual (aclass, aclass)
                             `connRet2` 
                             genAllCppHeaderInstNonVirtual classes
                        else "" 
      declBodyStr   = declDefStr 
                      `connRet2` 
                      classDeclsStr 
  in  renderTemplateGroup 
        templates 
        [ ("typemacro", typemacrostr)
        , ("cprefix", cprefix)
        , ("declarationheader", declHeaderStr ) 
        , ("declarationbody", declBodyStr ) ] 
        declarationTemplate

-- | 
mkDefMain :: STGroup String 
          -> ClassImportHeader 
          -> String 
mkDefMain templates header =
  let classes = [cihClass header]
      headerStr = genAllCppHeaderInclude header ++ "\n#include \"" ++ (T.unHdrName (cihSelfHeader header)) ++ "\"" 
      namespaceStr = (concatMap (\x->"using namespace " ++ unNamespace x ++ ";\n") . cihNamespace) header
      aclass = cihClass header
      cppBody = mkProtectedFunctionList (cihClass header) 
                `connRet`
                mkParentDef genCppDefInstVirtual (cihClass header)
                `connRet` 
                if isAbstractClass aclass 
                  then "" 
                  else genCppDefInstVirtual (aclass, aclass)
                `connRet`
                genAllCppDefInstNonVirtual classes
  in  renderTemplateGroup 
        templates 
        [ ("header" , headerStr ) 
        , ("namespace", namespaceStr ) 
        , ("cppbody", cppBody )  
        ] 
        definitionTemplate


-- | 
mkTopLevelFunctionHeader :: STGroup String 
                         -> T.TypeMacro  -- ^ typemacro prefix 
                         -> String     -- ^ C prefix 
                         -> TopLevelImportHeader
                         -> String 
mkTopLevelFunctionHeader templates (T.TypMcro typemacroprefix) cprefix tih =
  let typemacrostr = typemacroprefix ++ "TOPLEVEL" ++ "__" 
      declHeaderStr = intercalateWith connRet (\x->"#include \""++x++"\"")
                      . map (T.unHdrName . cihSelfHeader) . tihClassDep $ tih
      declBodyStr    = intercalateWith connRet genTopLevelFuncCppHeader (tihFuncs tih)
  in  renderTemplateGroup 
        templates 
        [ ("typemacro", typemacrostr)
        , ("cprefix", cprefix)
        , ("declarationheader", declHeaderStr ) 
        , ("declarationbody", declBodyStr ) ] 
        declarationTemplate


-- | 
mkTopLevelFunctionCppDef :: STGroup String 
                         -> String     -- ^ C prefix 
                         -> TopLevelImportHeader
                         -> String 
mkTopLevelFunctionCppDef templates cprefix tih =
  let cihs = tihClassDep tih
      declHeaderStr = "#include \"" ++ tihHeaderFileName tih <.> "h" ++ "\""
                      `connRet2`
                      (intercalate "\n" (nub (map genAllCppHeaderInclude cihs)))
                      `connRet2`
                      ((intercalateWith connRet (\x->"#include \""++x++"\"") . map (T.unHdrName . cihSelfHeader)) cihs)
      allns = nubBy ((==) `on` unNamespace) (tihClassDep tih >>= cihNamespace)
      namespaceStr = do ns <- allns 
                        ("using namespace " ++ unNamespace ns ++ ";\n")
      declBodyStr    = intercalateWith connRet genTopLevelFuncCppDefinition (tihFuncs tih)

  in  renderTemplateGroup 
        templates 
        [ ("header", declHeaderStr)
        , ("namespace", namespaceStr)
        , ("cppbody", declBodyStr ) ] 
        definitionTemplate

-- | 
mkFFIHsc :: STGroup String 
         -> ClassModule 
         -> String 
mkFFIHsc templates m = 
    renderTemplateGroup templates 
                        [ ("ffiHeader", ffiHeaderStr)
                        , ("ffiImport", ffiImportStr)
                        , ("cppInclude", cppIncludeStr)
                        , ("hsFunctionBody", genAllHsFFI headers) ]
                        ffiHscFileName
  where mname = cmModule m
        headers = cmCIH m
        ffiHeaderStr = "module " ++ mname <.> "FFI where\n"
        ffiImportStr = "import " ++ mname <.> "RawType\n"
                       ++ genImportInFFI m
        cppIncludeStr = genModuleIncludeHeader headers

-- |                      
mkRawTypeHs :: STGroup String 
            -> ClassModule 
            -> String
mkRawTypeHs templates m = 
    renderTemplateGroup templates [ ("rawtypeHeader", rawtypeHeaderStr) 
                                  , ("rawtypeBody", rawtypeBodyStr)] rawtypeHsFileName
  where rawtypeHeaderStr = "module " ++ cmModule m <.> "RawType where\n"
        classes = cmClass m
        rawtypeBodyStr = 
          intercalateWith connRet2 hsClassRawType (filter (not.isAbstractClass) classes)

-- | 
mkInterfaceHs :: AnnotateMap 
              -> STGroup String 
              -> ClassModule 
              -> String    
mkInterfaceHs amap templates m = 
    renderTemplateGroup templates [ ("ifaceHeader", ifaceHeaderStr) 
                                  , ("ifaceImport", ifaceImportStr)
                                  , ("ifaceBody", ifaceBodyStr)]  "Interface.hs" 
  where ifaceHeaderStr = "module " ++ cmModule m <.> "Interface where\n" 
        classes = cmClass m
        ifaceImportStr = genImportInInterface m
        ifaceBodyStr = 
          runReader (genAllHsFrontDecl classes) amap 
          `connRet2`
          intercalateWith connRet hsClassExistType (filter (not.isAbstractClass) classes) 
          `connRet2`
          runReader (genAllHsFrontUpcastClass (filter (not.isAbstractClass) classes)) amap  
          `connRet2`
          runReader (genAllHsFrontDowncastClass (filter (not.isAbstractClass) classes)) amap

-- | 
mkCastHs :: STGroup String -> ClassModule -> String    
mkCastHs templates m  = 
    renderTemplateGroup templates [ ("castHeader", castHeaderStr) 
                                  , ("castImport", castImportStr)
                                  , ("castBody", castBodyStr) ]  
                                  castHsFileName
  where castHeaderStr = "module " ++ cmModule m <.> "Cast where\n" 
        classes = cmClass m
        castImportStr = genImportInCast m
        castBodyStr = 
          genAllHsFrontInstCastable classes 
          `connRet2`
          intercalateWith connRet2 genHsFrontInstCastableSelf classes

-- | 
mkImplementationHs :: AnnotateMap 
                   -> STGroup String  -- ^ template 
                   -> ClassModule 
                   -> String
mkImplementationHs amap templates m = 
    renderTemplateGroup templates 
                        [ ("implHeader", implHeaderStr) 
                        , ("implImport", implImportStr)
                        , ("implBody", implBodyStr ) ]
                        "Implementation.hs"
  where classes = cmClass m
        implHeaderStr = "module " ++ cmModule m <.> "Implementation where\n" 
        implImportStr = genImportInImplementation m
        f y = intercalateWith connRet (flip genHsFrontInst y) (y:class_allparents y )
        g y = intercalateWith connRet (flip genHsFrontInstExistVirtual y) (y:class_allparents y )

        implBodyStr =  
          intercalateWith connRet2 f classes
          `connRet2` 
          intercalateWith connRet2 g (filter (not.isAbstractClass) classes)
          `connRet2`
          runReader (genAllHsFrontInstNew classes) amap
          `connRet2`
          genAllHsFrontInstNonVirtual classes
          `connRet2`
          intercalateWith connRet id (mapMaybe genHsFrontInstStatic classes)
          `connRet2`
          genAllHsFrontInstExistCommon (filter (not.isAbstractClass) classes)
        
-- | 
mkExistentialEach :: STGroup String 
                  -> Class 
                  -> [Class] 
                  -> String 
mkExistentialEach templates mother daughters =   
  let makeOneDaughterGADTBody daughter = render hsExistentialGADTBodyTmpl 
                                                [ ( "mother", (fst.hsClassName) mother ) 
                                                , ( "daughter",(fst.hsClassName) daughter ) ] 
      makeOneDaughterCastBody daughter = render hsExistentialCastBodyTmpl
                                                [ ( "mother", (fst.hsClassName) mother ) 
                                                , ( "daughter", (fst.hsClassName) daughter) ] 
      gadtBody = intercalate "\n" (map makeOneDaughterGADTBody daughters)
      castBody = intercalate "\n" (map makeOneDaughterCastBody daughters)
      str = renderTemplateGroup 
              templates 
              [ ( "mother" , (fst.hsClassName) mother ) 
              , ( "GADTbody" , gadtBody ) 
              , ( "castbody" , castBody ) ]
              "ExistentialEach.hs" 
  in  str

-- | 
mkExistentialHs :: STGroup String 
                -> ClassGlobal 
                -> ClassModule 
                -> String
mkExistentialHs templates cglobal m = 
  let classes = filter (not.isAbstractClass) (cmClass m)
      dsmap = cgDaughterSelfMap cglobal
      makeOneMother :: Class -> String 
      makeOneMother mother = 
        let daughters = case M.lookup (getClassModuleBase mother) dsmap of 
                             Nothing -> error "error in mkExistential"
                             Just lst -> filter (not.isAbstractClass) lst
            str = mkExistentialEach templates mother daughters
        in  str 
      existEachBody = intercalateWith connRet makeOneMother classes
      existHeaderStr = "module " ++ cmModule m <.> "Existential where"
      existImportStr = genImportInExistential dsmap m
      hsfilestr = renderTemplateGroup 
                    templates 
                    [ ("existHeader", existHeaderStr)
                    , ("existImport", existImportStr)
                    , ("modname", cmModule m)
                    , ( "existEachBody" , existEachBody) ]
                  "Existential.hs" 
  in  hsfilestr

-- | 
mkInterfaceHSBOOT :: STGroup String -> String -> String 
mkInterfaceHSBOOT templates mname = 
  let cname = last (splitOn "." mname)
      hsbootbodystr = "class " ++ 'I':cname ++ " a" 
      hsbootstr = renderTemplateGroup 
                    templates 
                    [ ("moduleName", mname <.> "Interface") 
                    , ("hsBootBody", hsbootbodystr)
                    ]
                    hsbootTemplate
  in hsbootstr 



-- | 
mkModuleHs :: STGroup String 
           -> ClassModule 
           -> String 
mkModuleHs templates m = 
    let str = renderTemplateGroup 
                templates 
                [ ("moduleName", cmModule m) 
                , ("exportList", genExportList (cmClass m)) 
                , ("importList", genImportInModule (cmClass m))
                ]
                moduleTemplate 
    in str


-- | 
mkPkgHs :: String -> STGroup String -> [ClassModule] -> TopLevelImportHeader -> String 
mkPkgHs modname templates mods tih = 
    let tfns = tihFuncs tih 
        exportListStr = intercalateWith (conn "\n, ") ((\x->"module " ++ x).cmModule) mods 
                        ++ if null tfns 
                           then "" 
                           else "\n, " ++ intercalateWith (conn "\n, ") hsFrontNameForTopLevelFunction tfns 
        importListStr = intercalateWith connRet ((\x->"import " ++ x).cmModule) mods
                        ++ if null tfns 
                           then "" 
                           else "" `connRet2` "import Foreign.C" `connRet` "import Foreign.Ptr"
                                `connRet` "import FFICXX.Runtime.Cast" 
                                `connRet`
                                intercalateWith connRet 
                                  ((\x->"import " ++ modname ++ "." ++ x ++ ".RawType")
                                   .fst.hsClassName.cihClass) (tihClassDep tih)
        topLevelDefStr = intercalateWith connRet2 (genTopLevelFuncFFI tih) tfns 
                         `connRet2`
                         intercalateWith connRet2 genTopLevelFuncDef tfns
        str = renderTemplateGroup 
                templates 
                [ ("summarymod", modname)
                , ("exportList", exportListStr) 
                , ("importList", importListStr) 
                , ("topLevelDef", topLevelDefStr) 
                ]
                pkgModuleTemplate
    in str 
       


  
-- |
mkPackageInterface :: T.PackageInterface 
                   -> T.PackageName 
                   -> [ClassImportHeader] 
                   -> T.PackageInterface
mkPackageInterface pinfc pkgname = foldr f pinfc 
  where f cih repo = 
          let name = (class_name . cihClass) cih 
              header = cihSelfHeader cih 
          in set (at (pkgname,T.ClsName name)) (Just header) repo

