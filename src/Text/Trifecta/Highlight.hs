{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

#ifndef MIN_VERSION_lens
#define MIN_VERSION_lens(x,y,z) 1
#endif
-----------------------------------------------------------------------------
-- |
-- Copyright   :  (C) 2011-2015 Edward Kmett
-- License     :  BSD-style (see the file LICENSE)
--
-- Maintainer  :  Edward Kmett <ekmett@gmail.com>
-- Stability   :  experimental
-- Portability :  non-portable
--
----------------------------------------------------------------------------
module Text.Trifecta.Highlight
  ( Highlight
  , HighlightedRope(HighlightedRope)
  , HasHighlightedRope(..)
  , withHighlight
  , HighlightDoc(HighlightDoc)
  , HasHighlightDoc(..)
  , doc
  ) where

import Control.Lens
#if MIN_VERSION_lens(4,13,0) && __GLASGOW_HASKELL__ >= 710
  hiding (Empty)
#endif
import Data.Foldable as F
import Data.Int (Int64)
import Data.List (sort)
import Data.Semigroup
import Data.Semigroup.Union
import Data.Text.Prettyprint.Doc
import Data.Text.Prettyprint.Doc.Render.Terminal (color)
import qualified Data.Text.Prettyprint.Doc.Render.Terminal as Pretty
import Prelude hiding (head)
import Text.Blaze
import Text.Blaze.Html5 hiding (a,b,i)
import qualified Text.Blaze.Html5 as Html5
import Text.Blaze.Html5.Attributes hiding (title,id)
import Text.Blaze.Internal (MarkupM(Empty, Leaf))
import Text.Parser.Token.Highlight
import qualified Data.ByteString.Lazy.Char8 as L
import qualified Data.ByteString.Lazy.UTF8 as LazyUTF8

import Text.Trifecta.Util.IntervalMap as IM
import Text.Trifecta.Delta
import Text.Trifecta.Pretty
import Text.Trifecta.Rope

-- | Convert a 'Highlight' into a coloration on a 'Doc'.
withHighlight :: Highlight -> Doc AnsiStyle -> Doc AnsiStyle
withHighlight Comment                     = annotate (color Pretty.Blue)
withHighlight ReservedIdentifier          = annotate (color Pretty.Magenta)
withHighlight ReservedConstructor         = annotate (color Pretty.Magenta)
withHighlight EscapeCode                  = annotate (color Pretty.Magenta)
withHighlight Operator                    = annotate (color Pretty.Yellow)
withHighlight CharLiteral                 = annotate (color Pretty.Cyan)
withHighlight StringLiteral               = annotate (color Pretty.Cyan)
withHighlight Constructor                 = annotate Pretty.bold
withHighlight ReservedOperator            = annotate (color Pretty.Yellow)
withHighlight ConstructorOperator         = annotate (color Pretty.Yellow)
withHighlight ReservedConstructorOperator = annotate (color Pretty.Yellow)
withHighlight _                           = id

-- | A 'HighlightedRope' is a 'Rope' with an associated 'IntervalMap' full of highlighted regions.
data HighlightedRope = HighlightedRope
  { _ropeHighlights :: !(IM.IntervalMap Delta Highlight)
  , _ropeContent    :: {-# UNPACK #-} !Rope
  }

makeClassy ''HighlightedRope

instance HasDelta HighlightedRope where
  delta = delta . _ropeContent

instance HasBytes HighlightedRope where
  bytes = bytes . _ropeContent

instance Semigroup HighlightedRope where
  HighlightedRope h bs <> HighlightedRope h' bs' = HighlightedRope (h `union` IM.offset (delta bs) h') (bs <> bs')

instance Monoid HighlightedRope where
  mappend = (<>)
  mempty = HighlightedRope mempty mempty

data Located a = a :@ {-# UNPACK #-} !Int64
infix 5 :@
instance Eq (Located a) where
  _ :@ m == _ :@ n = m == n
instance Ord (Located a) where
  compare (_ :@ m) (_ :@ n) = compare m n

instance ToMarkup HighlightedRope where
  toMarkup (HighlightedRope intervals r) = Html5.pre $ go 0 lbs effects where
    lbs = L.fromChunks [bs | Strand bs _ <- F.toList (strands r)]
    ln no = Html5.a ! name (toValue $ "line-" ++ show no) $ emptyMarkup
    effects = sort $ [ i | (Interval lo hi, tok) <- intersections mempty (delta r) intervals
                     , i <- [ (leafMarkup "span" "<span" ">" ! class_ (toValue $ show tok)) :@ bytes lo
                            , preEscapedToHtml ("</span>" :: String) :@ bytes hi
                            ]
                     ] ++ imap (\k i -> ln k :@ i) (L.elemIndices '\n' lbs)
    go _ cs [] = unsafeLazyByteString cs
    go b cs ((eff :@ eb) : es)
      | eb <= b = eff >> go b cs es
      | otherwise = unsafeLazyByteString om >> go eb nom es
         where (om,nom) = L.splitAt (fromIntegral (eb - b)) cs

#if MIN_VERSION_blaze_markup(0,8,0)
    emptyMarkup = Empty ()
    leafMarkup a b c = Leaf a b c ()
#else
    emptyMarkup = Empty
    leafMarkup a b c = Leaf a b c
#endif

prettyRope :: HighlightedRope -> Doc AnsiStyle
prettyRope (HighlightedRope intervals r) = go mempty lbs boundaries where
  lbs = L.fromChunks [bs | Strand bs _ <- F.toList (strands r)]
  ints = intersections mempty (delta r) intervals
  boundaries = sort [ i | (Interval lo hi, _) <- ints, i <- [ lo, hi ] ]
  dominated l h = Prelude.foldr (fmap . withHighlight . snd) id (dominators l h intervals)
  go l cs [] = dominated l (delta r) $ pretty (LazyUTF8.toString cs)
  go l cs (h:es) = dominated l h (pretty (LazyUTF8.toString om)) <> go h nom es
    where (om,nom) = L.splitAt (fromIntegral (bytes h - bytes l)) cs

-- | Represents a source file like an HsColour rendered document
data HighlightDoc = HighlightDoc
  { _docTitle   :: String
  , _docCss     :: String -- href for the css file
  , _docContent :: HighlightedRope
  }

makeClassy ''HighlightDoc

-- | Generate an HTML document from a title and a 'HighlightedRope'.
doc :: String -> HighlightedRope -> HighlightDoc
doc t r = HighlightDoc t "trifecta.css" r

instance ToMarkup HighlightDoc where
  toMarkup (HighlightDoc t css cs) = docTypeHtml $ do
    head $ do
      preEscapedToHtml ("<!-- Generated by trifecta, http://github.com/ekmett/trifecta/ -->\n" :: String)
      title $ toHtml t
      link ! rel "stylesheet" ! type_ "text/css" ! href (toValue css)
    body $ toHtml cs
