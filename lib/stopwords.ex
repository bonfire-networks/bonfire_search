defmodule Bonfire.Search.Stopwords do
  @moduledoc """
  Handles matching of needs & offers
  """
  # stopword files available in /priv/ per language
  # data from http://www.nltk.org/nltk_data/
  @languages_available [
    "arabic",
    "dutch",
    "french",
    "hungarian",
    "kazakh",
    "portuguese",
    "russian",
    "swedish",
    "azerbaijani",
    "english",
    "german",
    "indonesian",
    "nepali",
    "slovene",
    "tajik",
    "danish",
    "finnish",
    "greek",
    "italian",
    "norwegian",
    "romanian",
    "spanish",
    "turkish"
  ]
  @default "english"

  @languages_stopwords (for lang <- @languages_available do
                          data =
                            "../priv/stopwords/#{lang}"
                            |> Path.expand(__DIR__)
                            |> File.read!()
                            |> String.split("\n")

                          {lang, data}
                        end)
                       |> Map.new()

  @doc """
  Filters out pre-defined stop words.
  """
  def filter(text, language \\ nil) do
    text
    |> split_sentences()
    |> Enum.map(&filter_sentence(&1, language))
    |> Enum.reject(&(&1 == []))
  end

  defp filter_sentence(text, language \\ nil) do
    text
    |> split_words()
    |> Enum.reject(&filter_stop_word(&1, language))
  end

  def split_sentences(text) do
    String.split(
      # PCRE taken from https://en.wikipedia.org/wiki/Sentence_boundary_disambiguation
      text,
      ~r/(?<!\..)([\?\!\.]+)\s(?!.\.)/u
    )
  end

  def split_words(text), do: FastNgram.word_ngrams(text, 1)

  defp filter_stop_word(word, language) do
    (word |> String.trim(".!?") |> String.downcase()) in stop_words(language)
  end

  def stop_words(language \\ @default)

  def stop_words(@default = lang),
    do:
      Map.get(@languages_stopwords, lang) ++
        [
          "offer",
          "offering",
          "needing",
          "need",
          "looking",
          "anyone",
          "anybody",
          "also",
          "please"
        ]

  def stop_words("french" = lang),
    do:
      Map.get(@languages_stopwords, lang) ++
        ["offre", "donne", "besoin", "cherche", "quelqu'un", "j'ai"]

  def stop_words(lang) when is_nil(lang) or lang == "", do: stop_words(@default)

  def stop_words(lang), do: Map.get(@languages_stopwords, lang)

  # File.read()
end
