module Routing
    exposing
        ( Route(..)
        , parseRoute
        , reverse
        , authRequired
        , newUrl
        )

import Navigation
import UrlParser as Url exposing ((</>), (<?>))
import Products.Pagination as Pagination
import Routing.Utils exposing (joinPath, withQueryStrings)
import SeedAttribute
import Search exposing (UniqueSearch(..))


type Route
    = ProductDetails String
    | CategoryDetails String Pagination.Data
    | AdvancedSearch
    | SearchResults Search.Data Pagination.Data
    | PageDetails String
    | CreateAccount
    | CreateAccountSuccess
    | Login
    | ResetPassword (Maybe String)
    | MyAccount
    | EditLogin
    | EditContact
    | Cart
    | QuickOrder
    | Checkout
    | CheckoutSuccess Int
    | NotFound


parseRoute : Navigation.Location -> Route
parseRoute =
    let
        searchParser =
            [ ( "all-products", identity )
            , ( "organic", (\s -> { s | isOrganic = True }) )
            , ( "heirloom", (\s -> { s | isHeirloom = True }) )
            , ( "south-east", (\s -> { s | isRegional = True }) )
            , ( "ecological", (\s -> { s | isEcological = True }) )
            ]
                |> List.map
                    (\( slug, modifier ) ->
                        Url.s slug
                            |> Url.map (SearchResults <| modifier Search.initial)
                            |> Pagination.fromQueryString
                    )
                |> (::)
                    (Url.map SearchResults (Url.s "search")
                        |> Search.fromQueryString
                        |> Pagination.fromQueryString
                    )
                |> Url.oneOf

        accountParser =
            Url.oneOf
                [ Url.map Login (Url.s "login")
                , Url.map CreateAccount (Url.s "create")
                , Url.map CreateAccountSuccess (Url.s "create" </> Url.s "success")
                , Url.map ResetPassword (Url.s "reset-password" <?> Url.stringParam "code")
                , Url.map MyAccount Url.top
                , Url.map EditLogin (Url.s "edit")
                , Url.map EditContact (Url.s "edit-contact")
                ]

        routeParser =
            Url.oneOf
                [ Url.map (PageDetails "home") Url.top
                , Url.map ProductDetails (Url.s "products" </> Url.string)
                , Url.map CategoryDetails (Url.s "categories" </> Url.string)
                    |> Pagination.fromQueryString
                , Url.map AdvancedSearch (Url.s "search" </> Url.s "advanced")
                , searchParser
                , Url.map SearchResults (Url.s "search")
                    |> Search.fromQueryString
                    |> Pagination.fromQueryString
                , Url.s "account" </> accountParser
                , Url.map Cart (Url.s "cart")
                , Url.map QuickOrder (Url.s "quick-order")
                , Url.map Checkout (Url.s "checkout")
                , Url.map CheckoutSuccess (Url.s "checkout" </> Url.s "success" </> Url.int)
                , Url.map PageDetails (Url.string)
                ]
    in
        Url.parsePath routeParser
            >> Maybe.withDefault NotFound


reverse : Route -> String
reverse route =
    case route of
        ProductDetails slug ->
            joinPath [ "products", slug ]

        CategoryDetails slug pagination ->
            joinPath [ "categories", slug ]
                ++ withQueryStrings
                    [ Pagination.toQueryString pagination ]

        AdvancedSearch ->
            joinPath [ "search", "advanced" ]

        SearchResults data pagination ->
            let
                specialSearchUrl str =
                    joinPath [ str ]
                        ++ withQueryStrings
                            [ Pagination.toQueryString pagination ]
            in
                case Search.uniqueSearch data of
                    Nothing ->
                        joinPath [ "search" ]
                            ++ withQueryStrings
                                [ Search.toQueryString data
                                , Pagination.toQueryString pagination
                                ]

                    Just searchType ->
                        case searchType of
                            AllProducts ->
                                specialSearchUrl "all-products"

                            AttributeSearch (SeedAttribute.Organic) ->
                                specialSearchUrl "organic"

                            AttributeSearch (SeedAttribute.Heirloom) ->
                                specialSearchUrl "heirloom"

                            AttributeSearch (SeedAttribute.Regional) ->
                                specialSearchUrl "south-east"

                            AttributeSearch (SeedAttribute.Ecological) ->
                                specialSearchUrl "ecological"

        PageDetails slug ->
            if slug == "home" then
                "/"
            else
                joinPath [ slug ]

        CreateAccount ->
            joinPath [ "account", "create" ]

        CreateAccountSuccess ->
            joinPath [ "account", "create", "success" ]

        Login ->
            joinPath [ "account", "login" ]

        ResetPassword _ ->
            joinPath [ "account", "reset-password" ]

        MyAccount ->
            joinPath [ "account" ]

        EditLogin ->
            joinPath [ "account", "edit" ]

        EditContact ->
            joinPath [ "account", "edit-contact" ]

        Cart ->
            joinPath [ "cart" ]

        QuickOrder ->
            joinPath [ "quick-order" ]

        Checkout ->
            joinPath [ "checkout" ]

        CheckoutSuccess orderId ->
            joinPath [ "checkout", "success", toString orderId ]

        NotFound ->
            joinPath [ "page-not-found" ]


authRequired : Route -> Bool
authRequired route =
    case route of
        ProductDetails _ ->
            False

        CategoryDetails _ _ ->
            False

        AdvancedSearch ->
            False

        SearchResults _ _ ->
            False

        PageDetails _ ->
            False

        CreateAccount ->
            False

        CreateAccountSuccess ->
            True

        Login ->
            False

        ResetPassword _ ->
            False

        MyAccount ->
            True

        EditLogin ->
            True

        EditContact ->
            True

        Cart ->
            False

        QuickOrder ->
            False

        Checkout ->
            False

        CheckoutSuccess _ ->
            True

        NotFound ->
            False


newUrl : Route -> Cmd msg
newUrl =
    reverse >> Navigation.newUrl
