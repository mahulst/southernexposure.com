{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
module Models.DB where

import Data.Int (Int64)
import Data.Time.Clock (UTCTime)
import Database.Persist.TH
import Numeric.Natural (Natural)

import Models.Fields

import qualified Data.Text as T


share [mkPersist sqlSettings, mkMigrate "migrateAll"] [persistLowerCase|
Category json
    name T.Text
    slug T.Text
    parentId CategoryId Maybe
    description T.Text
    imageUrl T.Text
    order Int
    UniqueCategorySlug slug
    deriving Show

Product json
    name T.Text
    slug T.Text
    categoryIds [CategoryId]
    baseSku T.Text
    shortDescription T.Text
    longDescription T.Text
    imageUrl T.Text
    UniqueProductSlug slug
    UniqueBaseSku baseSku
    deriving Show

ProductVariant json
    productId ProductId
    skuSuffix T.Text
    price Cents
    quantity Int64
    weight Milligrams
    isActive Bool
    UniqueSku productId skuSuffix
    deriving Show

SeedAttribute json
    productId ProductId
    isOrganic Bool
    isHeirloom Bool
    isEcological Bool
    isRegional Bool
    UniqueAttribute productId
    deriving Show


Page json
    name T.Text
    slug T.Text
    content T.Text
    UniquePageSlug slug
    deriving Show


Customer json
    firstName T.Text
    lastName T.Text
    addressOne T.Text
    addressTwo T.Text
    city T.Text
    state Region
    zipCode T.Text
    country Country
    telephone T.Text
    email T.Text
    encryptedPassword T.Text
    authToken T.Text
    isAdmin Bool default=false
    UniqueToken authToken
    UniqueEmail email

PasswordReset
    customerId CustomerId
    expirationTime UTCTime
    code T.Text
    UniquePasswordReset customerId
    UniqueResetCode code


Cart
    customerId CustomerId Maybe
    sessionToken T.Text Maybe
    expirationTime UTCTime Maybe
    UniqueCustomerCart customerId !force
    UniqueAnonymousCart sessionToken !force

CartItem
    cartId CartId
    productVariantId ProductVariantId
    quantity Natural
    UniqueCartItem cartId productVariantId


TaxRate
    description T.Text
    rate Natural
    country Country
    state Region Maybe
    excludedProductIds [ProductId]
    isActive Bool
    UniqueTaxRate country state !force

Surcharge
    description T.Text
    singleFee Cents
    multipleFee Cents
    categoryIds [CategoryId]
    isActive Bool
    UniqueSurcharge description

ShippingMethod
    description T.Text
    countries [Country]
    rates [ShippingRate]
    categoryIds [CategoryId]
    isActive Bool
    priority Natural


Address
    firstName T.Text
    lastName T.Text
    companyName T.Text
    addressOne T.Text
    addressTwo T.Text
    city T.Text
    state Region
    zipCode T.Text
    country Country
    type AddressType
    customerId CustomerId
    isActive Bool
    isDefault Bool

Order json
    customerId CustomerId
    status OrderStatus
    billingAddressId AddressId
    shippingAddressId AddressId
    taxDescription T.Text
    customerComment T.Text
    createdAt UTCTime

OrderLineItem json
    orderId OrderId
    type LineItemType
    description T.Text
    amount Cents

OrderProduct json
    orderId OrderId
    productVariantId ProductVariantId
    quantity Natural
    price Cents
    tax Cents
    UniqueOrderProduct orderId productVariantId
|]
