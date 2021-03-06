{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeFamilies #-}

import Control.Monad (forM, foldM, void)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Logger (runNoLoggingT)
import Data.ByteString.Lazy (ByteString)
import Data.Char (isAlpha)
import Data.Int (Int32)
import Data.List (nubBy)
import Data.Maybe (maybeToList)
import Data.Monoid ((<>))
import Data.Pool (destroyAllResources)
import Data.Scientific (Scientific)
import Database.MySQL.Base
    ( MySQLConn, Query(..), query_, close, MySQLValue(..), prepareStmt, queryStmt )
import Database.Persist
    ((<-.), (+=.), Entity(..), Filter, getBy, insert, insertMany_, upsert, deleteWhere, selectKeysList)
import Database.Persist.Postgresql
    (ConnectionPool, SqlWriteT, createPostgresqlPool, toSqlKey, runSqlPool)
import Numeric.Natural (Natural)
import System.FilePath (takeFileName)
import Text.Read (readMaybe)

import Models
import Models.Fields
import Utils

import qualified Data.ISO3166_CountryCodes as CountryCodes
import qualified Data.IntMap as IntMap
import qualified Data.StateCodes as StateCodes
import qualified Data.Text as T
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUID4
import qualified Models.ProvinceCodes as ProvinceCodes
import qualified System.IO.Streams as Streams


main :: IO ()
main = do
    mysqlConn <- connectToMysql
    psqlConn <- connectToPostgres
    mysqlProducts <- makeProducts mysqlConn
    categories <- makeCategories mysqlConn
    let products = nubBy (\(_, p1) (_, p2) -> productBaseSku p1 == productBaseSku p2)
            $ map (\(_, catId, _, _, _, _, p) -> (catId, p)) mysqlProducts
        variants = makeVariants mysqlProducts
    attributes <- makeSeedAttributes mysqlConn
    pages <- makePages mysqlConn
    customers <- makeCustomers mysqlConn
    carts <- makeCustomerCarts mysqlConn
    flip runSqlPool psqlConn $
        dropNewDatabaseRows >>
        insertCategories categories >>=
        insertProducts products >>
        insertVariants variants >>= \variantMap ->
        insertAttributes attributes >>
        insertPages pages >>
        insertCustomers customers >>= \customerMap ->
        insertCharges >>
        insertCustomerCarts variantMap customerMap carts
    close mysqlConn
    destroyAllResources psqlConn


type OldIdMap a = IntMap.IntMap a


-- DB Utility Functions

connectToPostgres :: IO ConnectionPool
connectToPostgres =
    runNoLoggingT $ createPostgresqlPool "dbname=sese-website" 1


dropNewDatabaseRows :: SqlWriteT IO ()
dropNewDatabaseRows =
    deleteWhere ([] :: [Filter SeedAttribute])
        >> deleteWhere ([] :: [Filter TaxRate])
        >> deleteWhere ([] :: [Filter Surcharge])
        >> deleteWhere ([] :: [Filter ShippingMethod])
        >> deleteWhere ([] :: [Filter CartItem])
        >> deleteWhere ([] :: [Filter Cart])
        >> deleteWhere ([] :: [Filter OrderProduct])
        >> deleteWhere ([] :: [Filter OrderLineItem])
        >> deleteWhere ([] :: [Filter Order])
        >> deleteWhere ([] :: [Filter Address])
        >> deleteWhere ([] :: [Filter ProductVariant])
        >> deleteWhere ([] :: [Filter Product])
        >> deleteWhere ([] :: [Filter Category])
        >> deleteWhere ([] :: [Filter Page])
        >> deleteWhere ([] :: [Filter Customer])


-- MySQL -> Persistent Functions

makeCategories :: MySQLConn -> IO [(Int, Int, Category)]
makeCategories mysql = do
    categories <- mysqlQuery mysql $
        "SELECT c.categories_id, categories_image, parent_id, sort_order,"
        <> "    categories_name, categories_description "
        <> "FROM categories as c "
        <> "LEFT JOIN categories_description as cd ON c.categories_id=cd.categories_id "
        <> "WHERE categories_status=1 "
        <> "ORDER BY parent_id ASC"
    mapM toData categories
    where toData [ MySQLInt32 catId, nullableImageUrl
                 , MySQLInt32 parentId, MySQLInt32 catOrder
                 , MySQLText name, MySQLText description
                 ] =
            let
                imgUrl =
                    case nullableImageUrl of
                        MySQLText str ->
                            str
                        _ ->
                            ""
            in
                return
                    ( fromIntegral catId
                    , fromIntegral parentId
                    , Category name (slugify name) Nothing description (T.pack . takeFileName $ T.unpack imgUrl) (fromIntegral catOrder)
                    )
          toData r = print r >> error "Category Lambda Did Not Match"


makeProducts :: MySQLConn -> IO [(Int32, Int, T.Text, Scientific, Float, Float, Product)]
makeProducts mysql = do
    products <- mysqlQuery mysql $
        "SELECT products_id, master_categories_id, products_price,"
        <> "    products_quantity, products_weight, products_model,"
        <> "    products_image, products_status "
        <> "FROM products "
        <> "WHERE products_status=1"
    forM products $
        \[ MySQLInt32 prodId, MySQLInt32 catId, MySQLDecimal prodPrice
         , MySQLFloat prodQty, MySQLFloat prodWeight, MySQLText prodSKU
         , MySQLText prodImg, _] -> do
            queryString <- prepareStmt mysql . Query $
                "SELECT products_id, products_name, products_description "
                <> "FROM products_description WHERE products_id=?"
            (_, descriptionStream) <- queryStmt mysql queryString [MySQLInt32 prodId]
            [_, MySQLText name, MySQLText description] <- head <$> Streams.toList descriptionStream
            _ <- return prodId
            _ <- return prodQty
            let (baseSku, skuSuffix) = splitSku prodSKU
            return ( prodId, fromIntegral catId, skuSuffix
                   , prodPrice, prodQty, prodWeight
                   , Product
                        { productName = name
                        , productSlug = slugify name
                        , productCategoryIds = []
                        , productBaseSku = T.toUpper baseSku
                        , productShortDescription = ""
                        , productLongDescription = description
                        , productImageUrl = T.pack . takeFileName $ T.unpack prodImg
                        }
                   )


makeVariants :: [(Int32, Int, T.Text, Scientific, Float, Float, Product)] -> [(Int, T.Text, ProductVariant)]
makeVariants =
    map makeVariant
    where makeVariant (productId, _, suffix, price, qty, weight, prod) =
            (fromIntegral productId, productBaseSku prod,) $
                ProductVariant
                    (toSqlKey 0)
                    (T.toUpper suffix)
                    (Cents . round $ 100 * price)
                    (floor qty)
                    (Milligrams . round $ 1000 * weight)
                    True


makeSeedAttributes :: MySQLConn -> IO [(T.Text, SeedAttribute)]
makeSeedAttributes mysql = do
    attributes <- mysqlQuery mysql $
        "SELECT p.products_id, products_model, is_eco,"
        <> "    is_organic, is_heirloom, is_southern "
        <> "FROM sese_products_icons as i "
        <> "RIGHT JOIN products AS p "
        <> "ON p.products_id=i.products_id "
        <> "WHERE p.products_status=1"
    nubBy (\a1 a2 -> fst a1 == fst a2) <$> mapM toData attributes
    where toData [ MySQLInt32 _, MySQLText prodSku, MySQLInt8 isEco
                 , MySQLInt8 isOrg, MySQLInt8 isHeir, MySQLInt8 isRegion
                 ] =
            return . (fst $ splitSku prodSku,) $
                SeedAttribute (toSqlKey 0) (toBool isOrg) (toBool isHeir)
                    (toBool isEco) (toBool isRegion)
          toData r = print r >> error "seed attribute lambda did not match"
          toBool = (==) 1


splitSku :: T.Text -> (T.Text, T.Text)
splitSku fullSku =
    case T.split isAlpha fullSku of
         [baseSku, ""] ->
            case T.stripPrefix baseSku fullSku of
                Just skuSuffix ->
                    (baseSku, skuSuffix)
                Nothing ->
                    (fullSku, "")
         _ ->
            (fullSku, "")


makePages :: MySQLConn -> IO [Page]
makePages mysql = do
    pages <- Streams.toList . snd
        =<< (query_ mysql . Query
            $ "SELECT pages_title, pages_html_text"
            <> "    FROM ezpages WHERE pages_html_text <> \"\"")
    return $ flip map pages $ \[MySQLText name, MySQLText content] ->
        Page name (slugify name) content


makeCustomers :: MySQLConn -> IO [(Int, Customer)]
makeCustomers mysql = do
    customers <- Streams.toList . snd
        =<< (query_ mysql . Query
                $ "SELECT c.customers_firstname, c.customers_lastname, c.customers_email_address,"
                <> "      c.customers_telephone, c.customers_password, a.entry_street_address,"
                <> "      a.entry_suburb, a.entry_postcode, a.entry_city,"
                <> "      a.entry_state, z.zone_name, co.countries_iso_code_2,"
                <> "      c.customers_id "
                <> "FROM customers AS c "
                <> "RIGHT JOIN address_book AS a "
                <> "    ON c.customers_default_address_id=a.address_book_id "
                <> "LEFT JOIN zones AS z "
                <> "    ON a.entry_zone_id=z.zone_id "
                <> "RIGHT JOIN countries as co "
                <> "    ON entry_country_id=co.countries_id "
                <> "WHERE c.COWOA_account=0"
            )
    forM customers $
        \[ MySQLText firstName, MySQLText lastName, MySQLText email
         , MySQLText telephone, MySQLText _, MySQLText address
         , MySQLText addressTwo , MySQLText zipCode, MySQLText city
         , MySQLText state , nullableZoneName, MySQLText rawCountryCode
         , MySQLInt32 customerId
         ] ->
        let
            zone =
                case nullableZoneName of
                    MySQLText text ->
                        text
                    _ ->
                        state
            country =
                case zone of
                    "Federated States Of Micronesia" ->
                        Country CountryCodes.FM
                    "Marshall Islands" ->
                        Country CountryCodes.MH
                    _ ->
                        case readMaybe (T.unpack rawCountryCode) of
                            Just countryCode ->
                                Country countryCode
                            Nothing ->
                                case rawCountryCode of
                                    "AN" ->
                                        Country CountryCodes.BQ
                                    _ ->
                                        error $ "Invalid Country Code: " ++ T.unpack rawCountryCode
            region =
                case fromCountry country of
                    CountryCodes.US ->
                        case StateCodes.fromMName zone of
                            Just stateCode ->
                                USState stateCode
                            Nothing ->
                                case zone of
                                    "Armed Forces Africa" ->
                                        USArmedForces AE
                                    "Armed Forces Canada" ->
                                        USArmedForces AE
                                    "Armed Forces Europe" ->
                                        USArmedForces AE
                                    "Armed Forces Middle East" ->
                                        USArmedForces AE
                                    "Armed Forces Pacific" ->
                                        USArmedForces AP
                                    "Armed Forces Americas" ->
                                        USArmedForces AA
                                    "Virgin Islands" ->
                                        USState StateCodes.VI
                                    _ ->
                                        error $ "Invalid State Code: " ++ T.unpack zone
                    CountryCodes.CA ->
                        case ProvinceCodes.fromMName zone of
                            Just provinceCode ->
                                CAProvince provinceCode
                            Nothing ->
                                case zone of
                                    "Yukon Territory" ->
                                        CAProvince ProvinceCodes.YT
                                    "Newfoundland" ->
                                        CAProvince ProvinceCodes.NL
                                    _ ->
                                        error $ "Invalid Canadian Province: " ++ T.unpack zone
                    _ ->
                        CustomRegion zone

        in do
            token <- generateToken
            return . (fromIntegral customerId,) $ Customer
                { customerFirstName = firstName
                , customerLastName = lastName
                , customerAddressOne = address
                , customerAddressTwo = addressTwo
                , customerCity = city
                , customerState = region
                , customerZipCode = zipCode
                , customerCountry = country
                , customerTelephone = telephone
                , customerEmail = email
                , customerEncryptedPassword = ""
                , customerAuthToken = token
                , customerIsAdmin = email == "gardens@southernexposure.com"
                }
    where generateToken = UUID.toText <$> UUID4.nextRandom


makeCustomerCarts :: MySQLConn -> IO (OldIdMap [(Int, Natural)])
makeCustomerCarts mysql = do
    cartItems <- mysqlQuery mysql $
        "SELECT customers_id, products_id, customers_basket_quantity " <>
        "FROM customers_basket ORDER BY customers_id"
    return $ foldl
        (\acc [MySQLInt32 customerId, MySQLText productsId, MySQLFloat quantity] ->
            IntMap.insertWith (++) (fromIntegral customerId)
                [(parseProductId productsId, round quantity)] acc
        )
        IntMap.empty cartItems
    where parseProductId productId =
            case T.split (== ':') productId of
                [] ->
                    error "makeCustomerCarts: T.split returned an empty list!"
                integerPart : _ ->
                    read $ T.unpack integerPart


-- Persistent Model Saving Functions

insertCategories :: [(Int, Int, Category)] -> SqlWriteT IO (OldIdMap CategoryId)
insertCategories =
    foldM insertCategory IntMap.empty
    where insertCategory intMap (mysqlId, mysqlParentId, category) = do
            let maybeParentId =
                    IntMap.lookup mysqlParentId intMap
                category' =
                    category { categoryParentId = maybeParentId }
            categoryId <- insert category'
            return $ IntMap.insert mysqlId categoryId intMap


insertProducts :: [(Int, Product)] -> OldIdMap CategoryId -> SqlWriteT IO ()
insertProducts products categoryIdMap =
    mapM_ insertProduct products
    where insertProduct (mysqlCategoryId, prod) = do
            let categoryIds =
                    maybeToList $ IntMap.lookup mysqlCategoryId categoryIdMap
                product' = prod { productCategoryIds = categoryIds }
            insert product'


insertVariants :: [(Int, T.Text, ProductVariant)] -> SqlWriteT IO (OldIdMap ProductVariantId)
insertVariants =
    foldM insertVariant IntMap.empty
    where insertVariant intMap (oldProductId, baseSku, variant) = do
            maybeProduct <- getBy $ UniqueBaseSku baseSku
            case maybeProduct of
                Nothing ->
                    lift (putStrLn $ "No product for: " ++ show variant)
                        >> return intMap
                Just (Entity prodId _) ->
                    insertIntoIdMap intMap oldProductId
                        <$> insert variant { productVariantProductId = prodId }


insertAttributes :: [(T.Text, SeedAttribute)] -> SqlWriteT IO ()
insertAttributes =
    mapM_ insertAttribute
    where insertAttribute (baseSku, attribute) = do
            maybeProduct <- getBy $ UniqueBaseSku baseSku
            case maybeProduct of
                Nothing ->
                    lift . putStrLn $ "No product for: " ++ show attribute
                Just (Entity prodId _) ->
                    void . insert $ attribute { seedAttributeProductId = prodId }


insertPages :: [Page] -> SqlWriteT IO ()
insertPages = insertMany_


insertCustomers :: [(Int, Customer)] -> SqlWriteT IO (OldIdMap CustomerId)
insertCustomers =
    foldM insertCustomer IntMap.empty
    where insertCustomer intMap (oldCustomerId, customer) =
            insertIntoIdMap intMap oldCustomerId <$> insert customer


insertCharges :: SqlWriteT IO ()
insertCharges = do
    void . insert $
        TaxRate "VA Sales Tax (5.3%)" 53 (Country CountryCodes.US)
            (Just $ USState StateCodes.VA) [] True
    getBy (UniqueCategorySlug "potatoes") >>=
        maybe (return ()) (\(Entity catId _) -> void . insert $
            Surcharge "Potato Fee" (Cents 200) (Cents 400) [catId] True)
    getBy (UniqueCategorySlug "sweet-potatoes") >>=
        maybe (return ()) (\(Entity catId _) -> void . insert $
            Surcharge "Sweet Potato Fee" (Cents 200) (Cents 400) [catId] True)
    fallCategoryIds <- selectKeysList
        [ CategorySlug <-.
            [ "garlic", "asiatic-turban", "elephant-garlic", "garlic-samplers"
            , "softneck-braidable", "perennial-onions", "ginseng-goldenseal"
            ]
        ] []
    void . insert $
        Surcharge "Fall Item Fee" (Cents 200) (Cents 400) fallCategoryIds True
    void . insert $
        ShippingMethod "Shipping to USA" [Country CountryCodes.US]
            [ Flat (Cents 0) (Cents 350)
            , Flat (Cents 3000) (Cents 450)
            , Flat (Cents 5000) (Cents 550)
            , Flat (Cents 12000) (Cents 650)
            , Percentage (Cents 50000000) 5
            ]
            []
            True
            2
    void . insert $
        ShippingMethod "International Shipping"
            [Country CountryCodes.CA, Country CountryCodes.MX]
            [ Flat (Cents 0) (Cents 550)
            , Flat (Cents 3000) (Cents 750)
            , Flat (Cents 5000) (Cents 950)
            , Percentage (Cents 12000) 8
            , Percentage (Cents 50000000) 10
            ]
            []
            True
            2
    getBy (UniqueCategorySlug "request-a-catalog") >>=
        maybe (return ()) (\(Entity catId _) -> void . insert $
            ShippingMethod "Free Shipping" [Country CountryCodes.US]
                [Flat (Cents 0) (Cents 0)]
                [catId]
                True
                1
            )


insertCustomerCarts :: OldIdMap ProductVariantId
                    -> OldIdMap CustomerId
                    -> OldIdMap [(Int, Natural)]
                    -> SqlWriteT IO ()
insertCustomerCarts variantMap customerMap =
    IntMap.foldlWithKey (\acc k c -> acc >> newCart k c) (return ())
    where newCart oldCustomerId variantsAndQuantities =
            let
                maybeCustomerId = IntMap.lookup oldCustomerId customerMap
            in
                case maybeCustomerId of
                    Nothing ->
                        return ()
                    Just customerId -> do
                        cartId <- insertCart customerId
                        mapM_ (insertCartItem cartId) variantsAndQuantities
          insertCart customerId =
            insert Cart
                { cartCustomerId = Just customerId
                , cartSessionToken = Nothing
                , cartExpirationTime = Nothing
                }
          insertCartItem cartId (oldVariantId, quantity) =
            let
                maybeVariantId = IntMap.lookup oldVariantId variantMap
            in
                case maybeVariantId of
                    Nothing ->
                        return ()
                    Just variantId ->
                        void $ upsert
                            CartItem
                                { cartItemCartId = cartId
                                , cartItemProductVariantId = variantId
                                , cartItemQuantity = quantity
                                }
                            [ CartItemQuantity +=. quantity ]


-- Utils

mysqlQuery :: MySQLConn -> ByteString -> IO [[MySQLValue]]
mysqlQuery conn queryString =
    query_ conn (Query queryString) >>= Streams.toList . snd

insertIntoIdMap :: OldIdMap a -> IntMap.Key -> a -> OldIdMap a
insertIntoIdMap intMap key value =
    IntMap.insert key value intMap
