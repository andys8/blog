{-|
Copyright   : (c) Dave Laing, 2017
License     : BSD3
Maintainer  : dave.laing.80@gmail.com
Stability   : experimental
Portability : non-portable
-}
module People.Context (
    authorFieldCtx
  ) where

import Hakyll

import People.Common

authorFieldCtx :: Context String
authorFieldCtx =
  listFieldWith "authors" defaultContext $ \item -> do
    authors <- lookupAuthors item
    let
      f x =
        load .
        fromFilePath .
        concat $
        ["snippets/people/", x, "/posts.md"]
    maybe (return []) (traverse f) authors
