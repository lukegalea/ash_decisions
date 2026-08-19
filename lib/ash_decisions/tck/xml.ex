defmodule AshDecisions.Tck.Xml do
  @moduledoc """
  The small slice of `:xmerl` this package needs, wrapped so callers never touch records.

  Every lookup is by **local name**. DMN models in the TCK corpus span four namespace
  revisions (DMN 1.2 through 1.5) and are exported by half a dozen tools, so matching on a
  prefixed or namespaced element name means silently skipping a construct that is present.
  Matching the local name is the only thing that is stable across the corpus.
  """

  require Record

  Record.defrecordp(:xmlElement, Record.extract(:xmlElement, from_lib: "xmerl/include/xmerl.hrl"))
  Record.defrecordp(:xmlAttribute, Record.extract(:xmlAttribute, from_lib: "xmerl/include/xmerl.hrl"))
  Record.defrecordp(:xmlText, Record.extract(:xmlText, from_lib: "xmerl/include/xmerl.hrl"))

  @type element :: tuple()

  @doc "Parses a document, returning its root element."
  @spec parse(binary()) :: {:ok, element()} | {:error, String.t()}
  def parse(xml) when is_binary(xml) do
    # Bytes, not codepoints. `String.to_charlist/1` yields codepoints above 255 for any
    # non-ASCII character, and xmerl rejects those as illegal characters even though the
    # document declares UTF-8 -- it does its own decoding and expects the raw octets.
    # One TCK group (0102-feel-constants) contains a "\u0161" and is the only thing that
    # catches this.
    {doc, _rest} = :xmerl_scan.string(:binary.bin_to_list(xml), quiet: true)
    {:ok, doc}
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, "xml parse failed: #{inspect(reason)}"}
  end

  @doc "The element's local name, namespace prefix stripped."
  @spec local_name(element()) :: String.t()
  def local_name(el) when Record.is_record(el, :xmlElement) do
    el |> xmlElement(:name) |> Atom.to_string() |> strip_prefix()
  end

  @doc "Direct child elements, optionally filtered to one local name."
  @spec children(element()) :: [element()]
  def children(el) when Record.is_record(el, :xmlElement) do
    el |> xmlElement(:content) |> Enum.filter(&Record.is_record(&1, :xmlElement))
  end

  @spec children(element(), String.t()) :: [element()]
  def children(el, name), do: el |> children() |> Enum.filter(&(local_name(&1) == name))

  @doc "The first direct child with this local name, or nil."
  @spec child(element(), String.t()) :: element() | nil
  def child(el, name), do: el |> children(name) |> List.first()

  @doc "Every descendant with this local name, at any depth, in document order."
  @spec descendants(element(), String.t()) :: [element()]
  def descendants(el, name) do
    el
    |> children()
    |> Enum.flat_map(fn c ->
      here = if local_name(c) == name, do: [c], else: []
      here ++ descendants(c, name)
    end)
  end

  @doc "An attribute's value by local name, or nil."
  @spec attr(element(), String.t()) :: String.t() | nil
  def attr(el, name) when Record.is_record(el, :xmlElement) do
    el
    |> xmlElement(:attributes)
    |> Enum.find_value(fn a ->
      if a |> xmlAttribute(:name) |> Atom.to_string() |> strip_prefix() == name do
        a |> xmlAttribute(:value) |> to_string()
      end
    end)
  end

  @doc "The element's concatenated text content, trimmed."
  @spec text(element() | nil) :: String.t()
  def text(nil), do: ""
  def text(el), do: el |> raw_text() |> String.trim()

  @doc """
  The element's concatenated text content, **untrimmed**.

  Required for expected string values: `<value xsi:type="xsd:string">XYZ </value>` asserts a
  trailing space, and four groups in the corpus (the `substring`, `upper case`, `lower case`
  and `replace` function tests) exist precisely to check that it survives. Trimming here
  reports a correct engine as wrong.
  """
  @spec raw_text(element() | nil) :: String.t()
  def raw_text(nil), do: ""

  def raw_text(el) when Record.is_record(el, :xmlElement) do
    el
    |> xmlElement(:content)
    |> Enum.map(fn
      node when Record.is_record(node, :xmlText) -> node |> xmlText(:value) |> to_string()
      _ -> ""
    end)
    |> Enum.join()
  end

  defp strip_prefix(name) do
    case String.split(name, ":", parts: 2) do
      [_prefix, local] -> local
      [local] -> local
    end
  end
end
