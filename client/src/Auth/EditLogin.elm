module Auth.EditLogin
    exposing
        ( Form
        , initial
        , Msg
        , update
        , view
        )

import Dict
import Html exposing (..)
import Html.Attributes exposing (id)
import Html.Events exposing (onInput, onSubmit)
import Json.Decode as Decode
import Json.Encode as Encode exposing (Value)
import RemoteData exposing (WebData)
import Api
import Ports
import Routing exposing (Route(MyAccount, Login))
import Update.Utils exposing (noCommand)
import User exposing (AuthStatus(..))
import Views.HorizontalForm as Form


-- MODEL


type alias Form =
    { email : Maybe String
    , password : Maybe String
    , passwordConfirm : Maybe String
    , errors : Api.FormErrors
    }


initial : Form
initial =
    { email = Nothing
    , password = Nothing
    , passwordConfirm = Nothing
    , errors = Api.initialErrors
    }


encoder : Form -> Value
encoder { email, password } =
    let
        nullable =
            Maybe.map Encode.string >> Maybe.withDefault Encode.null
    in
        Encode.object
            [ ( "email", nullable email )
            , ( "password", nullable password )
            ]



-- UPDATE


type Msg
    = Email String
    | Password String
    | PasswordConfirm String
    | Submit
    | SubmitResponse (WebData (Result Api.FormErrors ()))


update : Msg -> Form -> AuthStatus -> ( Form, Cmd Msg )
update msg model authStatus =
    let
        nothingIfBlank str =
            if String.isEmpty str then
                Nothing
            else
                Just str
    in
        case msg of
            Email email ->
                { model | email = nothingIfBlank email }
                    |> noCommand

            Password password ->
                { model | password = nothingIfBlank password }
                    |> noCommand

            PasswordConfirm password ->
                { model | passwordConfirm = nothingIfBlank password }
                    |> noCommand

            Submit ->
                if (model.password /= model.passwordConfirm) then
                    { model
                        | errors =
                            Api.initialErrors
                                |> Api.addError "passwordConfirm" "Passwords do not match."
                                |> Api.addError "password" "Passwords do not match."
                    }
                        |> noCommand
                else
                    case authStatus of
                        Authorized user ->
                            ( { model | errors = Dict.empty }
                            , updateLoginDetails model user.authToken
                            )

                        _ ->
                            ( initial, Routing.newUrl Login )

            SubmitResponse response ->
                case response of
                    RemoteData.Success (Err errors) ->
                        ( { model | errors = errors }
                        , Ports.scrollToID "edit-form"
                        )

                    RemoteData.Success (Ok _) ->
                        ( initial, Cmd.batch [ Routing.newUrl MyAccount, Ports.scrollToTop ] )

                    _ ->
                        model |> noCommand


updateLoginDetails : Form -> String -> Cmd Msg
updateLoginDetails model token =
    Api.put Api.CustomerEditLogin
        |> Api.withJsonBody (encoder model)
        |> Api.withJsonResponse (Decode.succeed ())
        |> Api.withToken token
        |> Api.withErrorHandler SubmitResponse



-- VIEW


view : (Msg -> msg) -> Form -> AuthStatus -> List (Html msg)
view tagger model authStatus =
    let
        email =
            case model.email of
                Nothing ->
                    case authStatus of
                        Authorized user ->
                            user.email

                        Anonymous ->
                            ""

                Just email ->
                    email

        inputRow selector msg =
            Form.inputRow model.errors (selector model) (tagger << msg)

        inputs =
            [ Form.genericErrorText (not <| Dict.isEmpty model.errors)
            , inputRow (always email) Email False "Email" "email" "email"
            , inputRow (.password >> Maybe.withDefault "") Password False "Password" "password" "password"
            , inputRow (.passwordConfirm >> Maybe.withDefault "") PasswordConfirm False "Confirm Password" "passwordConfirm" "password"
            , Form.submitButton "Update" False
            ]
    in
        [ h1 [] [ text "Edit Login Details" ]
        , hr [] []
        , form [ id "edit-form", onSubmit <| tagger Submit ] inputs
        ]
