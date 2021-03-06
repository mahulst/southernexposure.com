{-# LANGUAGE OverloadedStrings #-}
module Emails
    ( send
    , EmailType(..)
    )
    where

import Control.Concurrent.Async (Async, async)
import Control.Monad.Reader (ask)
import Control.Monad.IO.Class (liftIO)
import Data.Pool (withResource)
import Network.HaskellNet.SMTP.SSL (authenticate, sendMimeMail, AuthType(PLAIN))
import Text.Blaze.Html.Renderer.Text (renderHtml)
import Text.Markdown (markdown, def)

import Config
import Models hiding (PasswordReset)
import Server

import qualified Data.Text as T
import qualified Data.Text.Lazy as L
import qualified Emails.AccountCreated as AccountCreated
import qualified Emails.PasswordReset as PasswordReset
import qualified Models.DB as DB


data EmailType
    = AccountCreated Customer
    | PasswordReset Customer DB.PasswordReset
    | PasswordResetSuccess Customer


-- TODO: Make Configurable
developmentEmailRecipient :: String
developmentEmailRecipient = "pavan@acorncommunity.org"


send :: EmailType -> App (Async ())
send email = ask >>= \cfg ->
    let
        -- TODO: Add a Name to the sender address(see source for sendMimeMail)
        -- TODO: Make Configurable
        sender =
            "gardens@southernexposure.com"

        recipient env =
            if env /= Production then
                developmentEmailRecipient
            else
                case email of
                    AccountCreated customer ->
                        T.unpack $ customerEmail customer
                    PasswordReset customer _ ->
                        T.unpack $ customerEmail customer
                    PasswordResetSuccess customer ->
                        T.unpack $ customerEmail customer

        domainName =
            case getEnv cfg of
                Development ->
                    "http://localhost:7000"
                Production ->
                    "https://www.southernexposure.com"


        (subject, message) =
            case email of
                AccountCreated customer ->
                    AccountCreated.get
                        (L.fromStrict $ customerFirstName customer)
                PasswordReset customer passwordReset ->
                    PasswordReset.get
                        (L.fromStrict $ customerFirstName customer)
                        domainName
                        (L.fromStrict $ passwordResetCode passwordReset)
                PasswordResetSuccess customer ->
                    PasswordReset.getSuccess
                        (L.fromStrict $ customerFirstName customer)
    in
        liftIO $ async $ withResource (getSmtpPool cfg) $ \conn -> do
            authSucceeded <- authenticate PLAIN (getSmtpUser cfg) (getSmtpPass cfg) conn
            if authSucceeded then
                sendMimeMail (recipient $ getEnv cfg) sender subject message
                    (renderHtml $ markdown def message) [] conn
            else
                -- TODO: Properly Log SMTP Auth Error
                print ("SMTP AUTHENTICATION FAILED" :: T.Text)
