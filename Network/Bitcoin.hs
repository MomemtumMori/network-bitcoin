{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveDataTypeable #-}
module Network.Bitcoin (
    callBitcoinAPI,
    BitcoinException(..)
)
where
import Control.Applicative
import Control.Exception
import Control.Monad
import Data.Aeson
import Data.Attoparsec
import Data.Maybe (fromJust)
import Data.Typeable
import Network.Browser
import Network.HTTP
import Network.URI (URI,parseURI)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import qualified Data.Map as M
import qualified Data.Text as T

data BitcoinRpcResponse = BitcoinRpcResponse {
        btcResult  :: Value,
        btcError   :: Value
    }
    deriving (Show)
instance FromJSON BitcoinRpcResponse where
    parseJSON (Object v) = BitcoinRpcResponse <$> v .: "result"
                                          <*> v .: "error"
    parseJSON _ = mzero

-- |A 'BitcoinException' is thrown when 'callBitcoinAPI' encounters an
-- error.  The API error code is represented as an @Int@, the message as
-- a @String@.
data BitcoinException
    = BitcoinApiError Int String
    deriving (Show,Typeable)
instance Exception BitcoinException

-- encodes an RPC request into a ByteString containing JSON
jsonRpcReqBody :: String -> [String] -> BL.ByteString
jsonRpcReqBody cmd params = encode $ object [
                "jsonrpc" .= ("2.0"::String),
                "method"  .= cmd,
                "params"  .= params,
                "id"      .= (1::Int)
              ]

-- |'callBitcoinAPI' is used to execute an authenticated API request
-- against a Bitcoin daemon.  The first three arguments specify
-- authentication details (url, username, password).
-- They're usually curried for convenience:
--
-- > callBTC = callBitcoinAPI "http://127.0.0.1:8332" "user" "password"
--
-- On error, throws a 'BitcoinException'
callBitcoinAPI :: String  -- ^ URL of the Bitcoin daemon, including port number
               -> String  -- ^ username
               -> String  -- ^ password
               -> String  -- ^ command name
               -> [String] -- ^ command arguments
               -> IO Value
callBitcoinAPI urlString username password command params = do
    (_,httpRes) <- browse $ do
        setOutHandler $ const $ return ()
        addAuthority authority
        setAllowBasicAuth True
        request $ httpRequest urlString $ jsonRpcReqBody command params
    let res = fromSuccess $ fromJSON $ toValue $ rspBody httpRes
    case res of
        BitcoinRpcResponse {btcError=Null} -> return $ btcResult res
        BitcoinRpcResponse {btcError=e}    -> throw $ buildBtcError e
    where authority     = btcAuthority urlString username password
          toStrict      = B.concat . BL.toChunks
          justParseJSON = fromJust . maybeResult . parse json
          toValue       = justParseJSON . toStrict

-- Internal helper functions to make callBitcoinAPI more readable
btcAuthority :: String -> String -> String -> Authority
btcAuthority urlString username password =
    AuthBasic {
        auRealm    = "jsonrpc",
        auUsername = username,
        auPassword = password,
        auSite     = uri
    }
    where uri = fromJust $ parseURI urlString
httpRequest :: String -> BL.ByteString -> Request BL.ByteString
httpRequest urlString jsonBody =
    (postRequest urlString){
        rqBody = jsonBody,
        rqHeaders = [
            mkHeader HdrContentType "application/json",
            mkHeader HdrContentLength (show $ BL.length jsonBody)
        ]
    }

fromSuccess (Success a) = a
fromSuccess (Error   s) = error s

buildBtcError :: Value -> BitcoinException
buildBtcError (Object o) = BitcoinApiError code msg
    where find k = fromSuccess . fromJSON . fromJust . M.lookup k
          code = find "code" o
          msg  = find "message" o
buildBtcError _ = error "Need an object to buildBtcError"