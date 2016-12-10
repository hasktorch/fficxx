{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-----------------------------------------------------------------------------
-- |
-- Module      : FFICXX.Generate.Code.HsFFI
-- Copyright   : (c) 2011-2016 Ian-Woo Kim
--
-- License     : BSD3
-- Maintainer  : Ian-Woo Kim <ianwookim@gmail.com>
-- Stability   : experimental
-- Portability : GHC
--
-----------------------------------------------------------------------------

module FFICXX.Generate.Code.HsFFI where

import           Data.Char (toLower)
import           Data.Text                              (Text)
import qualified Data.Text                         as T
import qualified Data.Text.Lazy                    as TL
import           Data.Text.Template                     hiding (render)
import           System.FilePath ((<.>))
-- 
import           FFICXX.Generate.Util 
import           FFICXX.Generate.Type.Class
import           FFICXX.Generate.Type.PackageInterface

genHsFFI :: ClassImportHeader -> String 
genHsFFI header =
  let c = cihClass header
      h = cihSelfHeader header
      allfns = concatMap (virtualFuncs . class_funcs) 
                         (class_allparents c)
               ++ (class_funcs c) 
  in  intercalateWith connRet2 (hsFFIClassFunc h c) allfns  

genAllHsFFI :: [ClassImportHeader] -> String 
genAllHsFFI = intercalateWith connRet2 genHsFFI 

--------

-- | this template will be deprecated 
ffistub :: Text
ffistub = "foreign import ccall \"$headerfilename ${classname}_${funcname}\" $hsfuncname \n  :: $hsargs"

-- | this template will be used.
ffiTemplate :: Text
ffiTemplate = "foreign import ccall \"$headerfilename $funcname\" $hsfuncname \n  :: $hsargs"


hsFFIClassFunc :: HeaderName -> Class -> Function -> String 
hsFFIClassFunc headerfilename c f = if isAbstractClass c 
                       then ""
                       else if (isNewFunc f || isStaticFunc f)
                              then subst ffistub
                                     (context [ ("headerfilename",(unHdrName headerfilename))
                                              , ("classname",class_name c)
                                              , ("funcname", aliasedFuncName c f)
                                              , ("hsfuncname",hscFuncName c f)
                                              , ("hsargs", hsFuncTypNoSelf c f)
                                              ]) 
                              else subst ffistub 
                                     (context [ ("headerfilename",(unHdrName headerfilename))
                                              , ("classname",class_name c)
                                              , ("funcname", aliasedFuncName c f)
                                              , ("hsfuncname",hscFuncName c f)
                                              , ("hsargs", hsFuncTyp c f)
                                              ]) 

----------------------------
-- for top level function -- 
----------------------------

genTopLevelFuncFFI :: TopLevelImportHeader -> TopLevelFunction -> String 
genTopLevelFuncFFI header tfn =
    case tfn of
      TopLevelFunction {..} ->  
	let fname = maybe toplevelfunc_name id toplevelfunc_alias
	    (x:xs)  = fname
	    headerfilename = tihHeaderFileName header <.> "h"
	    hfname = toLower x : xs 
	    cfname = "c_" ++ toLowers hfname 
	    args = toplevelfunc_args 
	    ret = toplevelfunc_ret         
	    argstr = concatMap ((++ " -> ") . hsargtype . fst) args ++ hsrettype ret 
        in subst ffiTemplate (context [ ("headerfilename", headerfilename      ) 
                                      , ("funcname"      , "TopLevel_" ++ fname)
                                      , ("hsfuncname"    , cfname              )
                                      , ("hsargs"        , argstr              ) ]) 
      TopLevelVariable {..} ->  
        let fname = maybe toplevelvar_name id toplevelvar_alias
	    (x:xs)  = fname
	    headerfilename = tihHeaderFileName header <.> "h"
	    hfname = toLower x : xs 
	    cfname = "c_" ++ toLowers hfname 
	    args = [] 
            ret = toplevelvar_ret         
            argstr = concatMap ((++ " -> ") . hsargtype . fst) args ++ hsrettype ret 
        in subst ffiTemplate (context [ ("headerfilename", headerfilename      ) 
                                      , ("funcname"      , "TopLevel_" ++ fname)
                                      , ("hsfuncname"    , cfname              )
                                      , ("hsargs"        , argstr              ) ]) 

  where hsargtype (CT ctype _) = hsCTypeName ctype
        hsargtype (CPT x _) = hsCppTypeName x 
        hsargtype SelfType = "genTopLevelFuncFFI : no self for top level function " 
        hsargtype _ = error "undefined hsargtype"

        hsrettype Void = "IO ()"
        hsrettype SelfType = "genTopLevelFuncFFI : no self for top level function "
        hsrettype (CT ctype _) = "IO " ++ hsCTypeName ctype
        hsrettype (CPT x _ ) = "IO " ++ hsCppTypeName x 


