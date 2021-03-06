{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}
module Routes.Products
    ( ProductAPI
    , productRoutes
    ) where

import Data.Aeson ((.=), (.:), (.:?), ToJSON(..), FromJSON(..), object, withObject)
import Database.Persist ((==.), (<-.), Entity(..), selectList, get, getBy)
import Servant ((:>), (:<|>)(..), Capture, QueryParam, ReqBody, Get, Post, JSON, throwError, err404)

import Models
import Server
import Routes.CommonData
import Routes.Utils (paginatedSelect)

import qualified Data.Text as T
import qualified Database.Esqueleto as E


type ProductAPI =
         "search" :> ProductsSearchRoute
    :<|> "details" :> ProductDetailsRoute

type ProductRoutes =
         (Maybe T.Text -> Maybe Int -> Maybe Int -> ProductsSearchParameters -> App ProductsSearchData)
    :<|> (T.Text -> App ProductDetailsData)

productRoutes :: ProductRoutes
productRoutes =
         productsSearchRoute
    :<|> productDetailsRoute


-- DETAILS


data ProductDetailsData =
    ProductDetailsData
        { pddProduct :: Entity Product
        , pddVariants :: [Entity ProductVariant]
        , pddSeedAttribute :: Maybe (Entity SeedAttribute)
        , pddCategories :: [Entity Category]
        , pddPredecessors :: [PredecessorCategory]
        } deriving (Show)

instance ToJSON ProductDetailsData where
    toJSON productData =
        object [ "product" .= toJSON (pddProduct productData)
               , "variants" .= toJSON (pddVariants productData)
               , "seedAttribute" .= toJSON (pddSeedAttribute productData)
               , "categories" .= toJSON (pddCategories productData)
               , "predecessors" .= toJSON (pddPredecessors productData)
               ]

type ProductDetailsRoute =
    Capture "slug" T.Text :> Get '[JSON] ProductDetailsData

-- TODO: Use Esqueleto library to make 1 query instead of 4
productDetailsRoute :: T.Text -> App ProductDetailsData
productDetailsRoute slug = do
        maybeProduct <- runDB . getBy $ UniqueProductSlug slug
        case maybeProduct of
            Nothing ->
                throwError err404
            Just e@(Entity productId prod) -> do
                (variants, maybeAttribute, categories) <- runDB $
                    (,,) <$> selectList [ProductVariantProductId ==. productId] []
                        <*> getBy (UniqueAttribute productId)
                        <*> selectList [CategoryId <-. productCategoryIds prod] []
                predecessors <- concat <$> mapM getParentCategories (productCategoryIds prod)
                return . ProductDetailsData e variants maybeAttribute categories
                    $ map categoryToPredecessor predecessors


-- SEARCH


data ProductsSearchParameters =
    ProductsSearchParameters
        { pspQuery :: T.Text
        , pspSearchDescription :: Bool
        , pspFilterOrganic :: Bool
        , pspFilterHeirloom :: Bool
        , pspFilterRegional :: Bool
        , pspFilterEcological :: Bool
        , pspCategoryId :: Maybe CategoryId
        } deriving (Show)

instance FromJSON ProductsSearchParameters where
    parseJSON =
        withObject "ProductsSearchParameters" $ \v ->
            ProductsSearchParameters
                <$> v .: "query"
                <*> v .: "searchDescription"
                <*> v .: "filterOrganic"
                <*> v .: "filterHeirloom"
                <*> v .: "filterRegional"
                <*> v .: "filterEcological"
                <*> v .:? "category"

data ProductsSearchData =
    ProductsSearchData
        { psdProductData :: [ProductData]
        , psdTotalProducts :: Int
        , psdCategoryName :: Maybe T.Text
        } deriving (Show)

instance ToJSON ProductsSearchData where
    toJSON searchData =
        object [ "products" .= toJSON (psdProductData searchData)
               , "total" .= toJSON (psdTotalProducts searchData)
               , "categoryName" .= toJSON (psdCategoryName searchData)
               ]

type ProductsSearchRoute =
       QueryParam "sortBy" T.Text
    :> QueryParam "page" Int
    :> QueryParam "perPage" Int
    :> ReqBody '[JSON] ProductsSearchParameters
    :> Post '[JSON] ProductsSearchData

productsSearchRoute :: Maybe T.Text -> Maybe Int -> Maybe Int -> ProductsSearchParameters -> App ProductsSearchData
productsSearchRoute maybeSort maybePage maybePerPage parameters = do
    let queryFilters p
            | pspQuery parameters /= "" && pspSearchDescription parameters =
                foldl1 (E.&&.) . map (nameOrDescription p) . T.words $ pspQuery parameters
            | pspQuery parameters /= "" =
                foldl1 (E.&&.) . map (nameFilter p) . T.words $ pspQuery parameters
            | otherwise =
                E.val True
        organicFilter =
            attributeFilter pspFilterOrganic SeedAttributeIsOrganic
        heirloomFilter =
            attributeFilter pspFilterHeirloom SeedAttributeIsHeirloom
        regionalFilter =
            attributeFilter pspFilterRegional SeedAttributeIsRegional
        ecologicalFilter =
            attributeFilter pspFilterEcological SeedAttributeIsEcological
    (categoryFilter, catName) <- case pspCategoryId parameters of
        Nothing ->
            return (const $ E.val True, Nothing)
        Just cId -> do
            name <- fmap categoryName <$> runDB (get cId)
            categories <- getChildCategoryIds cId
            return (\p -> p E.^. ProductCategoryIds `E.in_` E.valList (map (: []) categories), name)
    (products, productsCount) <- paginatedSelect
        maybeSort maybePage maybePerPage
        (\p sa -> queryFilters p E.&&. organicFilter sa E.&&. heirloomFilter sa E.&&.
                  regionalFilter sa E.&&. ecologicalFilter sa E.&&.
                  categoryFilter p)
    searchData <- mapM (getProductData . truncateDescription) products
    return $ ProductsSearchData searchData productsCount catName
    where fuzzyILike f s =
            f `E.ilike` ((E.%) E.++. E.val s E.++. (E.%))
          nameOrDescription p w =
                (p E.^. ProductName) `fuzzyILike` w E.||.
                (p E.^. ProductLongDescription) `fuzzyILike` w
          nameFilter p w =
                (p E.^. ProductName) `fuzzyILike` w
          attributeFilter selector attribute sa =
              if selector parameters then
                sa E.?. attribute E.==. E.just (E.val True)
              else
                E.val True
