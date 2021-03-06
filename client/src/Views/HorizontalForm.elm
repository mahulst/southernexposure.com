module Views.HorizontalForm
    exposing
        ( genericErrorText
        , selectRow
        , inputRow
        , withLabel
        , submitButton
        )

import Dict
import Html exposing (..)
import Html.Attributes exposing (id, class, for, name, type_, required, value)
import Html.Events exposing (onInput, on, targetValue)
import Json.Decode as Decode exposing (Decoder)
import Api


genericErrorText : Bool -> Html msg
genericErrorText hasErrors =
    if hasErrors then
        div [ id "form-errors-text", class "alert alert-danger" ]
            [ text <|
                "There were issues processing your request, "
                    ++ "please correct any errors highlighted below "
                    ++ "& resubmit the form."
            ]
    else
        text ""


submitButton : String -> Bool -> Html msg
submitButton content showRequiredLabel =
    let
        requiredLabel =
            if showRequiredLabel then
                small [ class "font-weight-bold text-danger" ] [ text "* Required Fields" ]
            else
                text ""
    in
        div [ class "form-group clearfix" ]
            [ requiredLabel
            , button [ class "btn btn-primary float-right", type_ "submit" ]
                [ text content ]
            ]


{-| TODO: Have users define a Field type w/ functions to convert to required
arguments, then pass these functions to a config function that returns a
version of this function that just takes a Field type?
-}
inputRow : Api.FormErrors -> String -> (String -> msg) -> Bool -> String -> String -> String -> Html msg
inputRow errors inputValue inputMsg isRequired labelText errorField inputType =
    let
        inputId =
            String.filter (\c -> c /= ' ') labelText

        fieldErrors =
            Dict.get errorField errors
                |> Maybe.withDefault []

        inputClass =
            if List.isEmpty fieldErrors && not (Dict.isEmpty errors) then
                "form-control is-valid"
            else if List.isEmpty fieldErrors then
                "form-control"
            else
                "form-control is-invalid"

        errorHtml =
            if List.isEmpty fieldErrors then
                text ""
            else
                fieldErrors
                    |> List.map text
                    |> List.intersperse (br [] [])
                    |> div [ class "invalid-feedback" ]
    in
        input
            [ id <| "input" ++ inputId
            , name inputId
            , class inputClass
            , type_ inputType
            , value inputValue
            , required isRequired
            , onInput inputMsg
            ]
            []
            |> (\i -> [ i, errorHtml ])
            |> withLabel labelText isRequired


selectRow : (String -> Result String a) -> (a -> msg) -> String -> Bool -> List (Html msg) -> Html msg
selectRow parser msg labelText isRequired options =
    let
        inputId =
            "input" ++ String.filter (\c -> c /= ' ') labelText

        onSelect msg =
            targetValue
                |> Decode.andThen decoder
                |> Decode.map msg
                |> on "change"

        decoder str =
            case parser str of
                Ok x ->
                    Decode.succeed x

                Err e ->
                    Decode.fail e
    in
        select [ id inputId, class "form-control", onSelect msg ] options
            |> List.singleton
            |> withLabel labelText isRequired


withLabel : String -> Bool -> List (Html msg) -> Html msg
withLabel labelText isRequired input =
    let
        inputId =
            String.filter (\c -> c /= ' ') labelText

        requiredHtml isRequired =
            if isRequired then
                span [ class "text-danger" ] [ text "*" ]
            else
                text ""
    in
        div [ class "form-group form-row align-items-center" ]
            [ label
                [ class "col-sm-3 col-form-label text-right font-weight-bold"
                , for <| "input" ++ inputId
                ]
                [ requiredHtml isRequired, text " ", text <| labelText ++ ":" ]
            , div [ class "col" ] input
            ]
