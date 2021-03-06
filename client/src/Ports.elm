port module Ports
    exposing
        ( setPageTitle
        , scrollToTop
        , scrollToID
        , collapseMobileMenus
        , storeAuthDetails
        , removeAuthDetails
        , loggedIn
        , loggedOut
        , storeCartSessionToken
        , removeCartSessionToken
        , newCartSessionToken
        , setCartItemCount
        , cartItemCountChanged
        )

-- Page Change


port setPageTitle : String -> Cmd msg


port scrollToSelector : String -> Cmd msg


port collapseMobileMenus : () -> Cmd msg


scrollToTop : Cmd msg
scrollToTop =
    scrollToID "main"


scrollToID : String -> Cmd msg
scrollToID id =
    scrollToSelector <| "#" ++ id



-- Auth


port storeAuthDetails : ( String, Int ) -> Cmd msg


port removeAuthDetails : () -> Cmd msg


port loggedIn : ({ userId : Int, token : String } -> msg) -> Sub msg


port loggedOut : (() -> msg) -> Sub msg



-- Cart Sessions


port storeCartSessionToken : String -> Cmd msg


port removeCartSessionToken : () -> Cmd msg


port newCartSessionToken : (String -> msg) -> Sub msg



-- Cart Item Counts


port setCartItemCount : Int -> Cmd msg


port cartItemCountChanged : (Int -> msg) -> Sub msg
