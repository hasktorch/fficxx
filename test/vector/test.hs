{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}

import qualified Data.ByteString.Char8 as B

import Foreign.C.Types
import Foreign.Ptr
import Foreign.C.String

import           STD.CppString
import           STD.Vector.Template
import qualified STD.Vector.TH as TH

$(TH.genVectorInstanceFor ''CInt "int")
$(TH.genVectorInstanceFor ''CppString "string")

main1 = do
  v :: Vector CInt <- newVector
  n <- size v
  print =<< size v

  push_back v 1
  print =<< size v
  mapM_ (push_back v) [1..100]
  print =<< size v
  pop_back v
  print =<< size v

  print =<< at v 5
  deleteVector v

main = do
  v :: Vector CppString <- newVector
  deleteVector v
