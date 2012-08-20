{-# LANGUAGE CPP, DeriveDataTypeable, DeriveFunctor  #-}
{-# LANGUAGE FlexibleInstances, TypeSynonymInstances #-}
{-# LANGUAGE PatternGuards, ScopedTypeVariables      #-}

------------------------------------------------------------------------------
-- |
-- Module:      Database.SQLite.Simple.FromField
-- Copyright:   (c) 2011 MailRank, Inc.
--              (c) 2011-2012 Leon P Smith
--              (c) 2012 Janne Hellsten
-- License:     BSD3
-- Maintainer:  Janne Hellsten <jjhellst@gmail.com>
-- Stability:   experimental
-- Portability: portable
--
-- The 'FromField' typeclass, for converting a single value in a row
-- returned by a SQL query into a more useful Haskell representation.
--
-- A Haskell numeric type is considered to be compatible with all
-- SQLite numeric types that are less accurate than it. For instance,
-- the Haskell 'Double' type is compatible with the SQLite's 32-bit
-- @Int@ type because it can represent a @Int@ exactly. On the other hand,
-- since a 'Double' might lose precision if representing a 64-bit @BigInt@,
-- the two are /not/ considered compatible.
--
------------------------------------------------------------------------------

module Database.SQLite.Simple.FromField
    (
      FromField(..)
    , FieldParser
    , ResultError(..)
    , Field
    ) where

import           Control.Applicative (Applicative, (<$>), pure)
import           Control.Exception (SomeException(..), Exception)
import           Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as B
import           Data.Int (Int16, Int32, Int64)
import           Data.Time (UTCTime, Day)
import           Data.Time.Format (parseTime)
import qualified Data.Text as T
import           Data.Typeable (Typeable, typeOf)

import           System.Locale (defaultTimeLocale)

import           Database.SQLite3 as Base
import           Database.SQLite.Simple.Types
import           Database.SQLite.Simple.Internal
import           Database.SQLite.Simple.Ok

-- | Exception thrown if conversion from a SQL value to a Haskell
-- value fails.
data ResultError = Incompatible { errSQLType :: String
                                , errHaskellType :: String
                                , errMessage :: String }
                 -- ^ The SQL and Haskell types are not compatible.
                 | UnexpectedNull { errSQLType :: String
                                  , errHaskellType :: String
                                  , errMessage :: String }
                 -- ^ A SQL @NULL@ was encountered when the Haskell
                 -- type did not permit it.
                 | ConversionFailed { errSQLType :: String
                                    , errHaskellType :: String
                                    , errMessage :: String }
                 -- ^ The SQL value could not be parsed, or could not
                 -- be represented as a valid Haskell value, or an
                 -- unexpected low-level error occurred (e.g. mismatch
                 -- between metadata and actual data in a row).
                   deriving (Eq, Show, Typeable)

instance Exception ResultError

left :: Exception a => a -> Ok b
left = Errors . (:[]) . SomeException

type FieldParser a = Field -> Ok a

-- | A type that may be converted from a SQL type.
class FromField a where
    fromField :: FieldParser a
    -- ^ Convert a SQL value to a Haskell value.
    --
    -- Returns a list of exceptions if the conversion fails.  In the case of
    -- library instances,  this will usually be a single 'ResultError',  but
    -- may be a 'UnicodeException'.
    --
    -- Implementations of 'fromField' should not retain any references to
    -- the 'Field' nor the 'ByteString' arguments after the result has
    -- been evaluated to WHNF.  Such a reference causes the entire
    -- @LibPQ.'PQ.Result'@ to be retained.
    --
    -- For example,  the instance for 'ByteString' uses 'B.copy' to avoid
    -- such a reference,  and that using bytestring functions such as 'B.drop'
    -- and 'B.takeWhile' alone will also trigger this memory leak.

instance (FromField a) => FromField (Maybe a) where
    fromField (Field SQLNull _) = pure Nothing
    fromField f                 = Just <$> fromField f

instance FromField Null where
    fromField (Field SQLNull _) = pure Null
    fromField f                 = returnError ConversionFailed f "data is not null"

takeInt :: (Num a, Typeable a) => Field -> Ok a
takeInt (Field (SQLInteger i) _) = Ok . fromIntegral $ i
takeInt f                        = returnError ConversionFailed f "need an int"

instance FromField Int16 where
    fromField = takeInt

instance FromField Int32 where
    fromField = takeInt

instance FromField Int where
    fromField = takeInt

instance FromField Int64 where
    fromField = takeInt

instance FromField Integer where
    fromField = takeInt

instance FromField Double where
    fromField (Field (SQLFloat flt) _) = Ok flt
    fromField f                        = returnError ConversionFailed f "need a float"

instance FromField T.Text where
    fromField (Field (SQLText txt) _) = Ok txt
    fromField f                       = returnError ConversionFailed f "need a text"

instance FromField [Char] where
  fromField (Field (SQLText t) _) = Ok $ T.unpack t
  fromField f                     = returnError ConversionFailed f "expecting SQLText column type"

-- TODO ToRow has both T and LB variants of ByteString, check what's
-- really needed here
instance FromField ByteString where
  fromField (Field (SQLBlob blb) _) = Ok blb
  fromField f                       = returnError ConversionFailed f "expecting SQLBlob column type"

instance FromField UTCTime where
  fromField f@(Field (SQLText t) _) =
    case parseTime defaultTimeLocale "%F %X%Q" . T.unpack $ t of
      Just t -> Ok t
      Nothing -> returnError ConversionFailed f "couldn't parse UTCTime field"

  fromField f                     = returnError ConversionFailed f "expecting SQLText column type"

instance FromField Day where
  fromField (Field (SQLText t) _) = Ok . read . T.unpack $ t
  fromField f                     = returnError ConversionFailed f "expecting SQLText column type"

fieldTypename :: Field -> String
fieldTypename = B.unpack . gettypename . result

-- | Given one of the constructors from 'ResultError',  the field,
--   and an 'errMessage',  this fills in the other fields in the
--   exception value and returns it in a 'Left . SomeException'
--   constructor.
returnError :: forall a err . (Typeable a, Exception err)
            => (String -> String -> String -> err)
            -> Field -> String -> Ok a
returnError mkErr f = left . mkErr (fieldTypename f)
                                   (show (typeOf (undefined :: a)))
