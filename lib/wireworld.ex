defmodule Wireworld do
  @moduledoc """
  Documentation for Wireworld.
  """

  @empt 0
  @wire 1
  @tail 2
  @elec 3

  @doc ~S"""
  Set up a state to start with.

  ## Examples

      iex> Wireworld.setup(:lines, "*@\n++")
      {4, 3, <<0, 0, 0, 0, 0, 2, 3, 0, 0, 1, 1, 0, 0, 0, 0, 0>>}

      iex> Wireworld.setup(:lines, "*@+\n| |\n+-+")
      {8, 4,
            <<0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 3, 1, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0,
              0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>}

  """
  def setup(type, data, opts \\ [])
  def setup(:lines, data, opts) when is_binary(data) do
    empt = List.wrap(opts[:empt] || [?\s])
    wire = List.wrap(opts[:wire] || [?c, ?., ?+, ?-, ?|])
    elec = List.wrap(opts[:elec] || [?e, ?H, ?@])
    tail = List.wrap(opts[:tail] || [?t, ?*])

    e = hd(empt)

    mapper = %{}
    mapper = Enum.reduce(empt, mapper, &Map.put_new(&2, &1, @empt))
    mapper = Enum.reduce(wire, mapper, &Map.put_new(&2, &1, @wire))
    mapper = Enum.reduce(elec, mapper, &Map.put_new(&2, &1, @elec))
    mapper = Enum.reduce(tail, mapper, &Map.put_new(&2, &1, @tail))

    lines = String.split("\n"<>data<>"\n", "\n")

    width = 1 + Enum.reduce(lines, 0, &if(byte_size(&1)>&2, do: byte_size(&1), else: &2))
    width_po2 = next_power_of_2(width)

    state =
      lines
      |> Enum.map(&setup_line(mapper, String.pad_trailing(<<e>> <> &1, width_po2, [<<e>>])))
      |> Enum.join()

    {width_po2, width, state}
  end

  defp setup_line(mapper, data, output \\ "")
  defp setup_line(_mapper, <<>>, output), do: output
  defp setup_line(mapper, <<c, rest::binary>>, output) do
    setup_line(mapper, rest, <<output::binary, Map.fetch!(mapper, c)>>)
  end

  defp next_power_of_2(num) do
    use Bitwise
    # Only caring up to 32 bits for width, if more should be supported then adjust this
    t = (num &&& 0xFFFF0000)
    num = if t===0, do: num, else: t
    t = (num &&& 0xFF00FF00)
    num = if t===0, do: num, else: t
    t = (num &&& 0xF0F0F0F0)
    num = if t===0, do: num, else: t
    t = (num &&& 0xCCCCCCCC)
    num = if t===0, do: num, else: t
    t = (num &&& 0xAAAAAAAA)
    num = if t===0, do: num, else: t
    num <<< 1
  end


  @doc ~S"""
  Get the current state as a string representation

  Pass in `colorized: true` to colorize the output.

  ## Examples

    iex> state = Wireworld.setup(:lines, "*@\n++")
    iex> Wireworld.to_string(state)
    "*@ \n++ \n   \n"
    iex> state = Wireworld.next_state(state)
    iex> Wireworld.to_string(state)
    "+* \n@@ \n   \n"

  """
  def to_string(state, opts \\ [])
  def to_string({width_po2, _width, state}, opts) do
    colorized = opts[:colorized] || false
    state
    |> :erlang.binary_to_list()
    |> Enum.chunk_every(width_po2)
    |> Enum.map(&[tl(Enum.map(&1, fn c -> to_string_value(c, colorized) end)), ?\n])
    |> tl()
    |> :erlang.iolist_to_binary()
  end


  defp to_string_value(@empt, _), do: ?\s
  defp to_string_value(@wire, false), do: ?+
  defp to_string_value(@wire, true),  do: [IO.ANSI.blue(), ?+, IO.ANSI.reset()]
  defp to_string_value(@tail, false), do: ?*
  defp to_string_value(@tail, true),  do: [IO.ANSI.yellow(), ?*, IO.ANSI.reset()]
  defp to_string_value(_, false),     do: ?@
  defp to_string_value(_, true),      do: [IO.ANSI.red(), ?@, IO.ANSI.reset()]


  @doc ~S"""
  Acquire the next state

  Pass in a `timeout: 5000` option to override the default timeout, maybe necessary for *very* large state

  ## Examples

    iex> state = Wireworld.setup(:lines, "*@\n++")
    iex> Wireworld.next_state(state)
    {4, 3, <<0, 0, 0, 0, 0, 1, 2, 0, 0, 3, 3, 0, 0, 0, 0, 0>>}

  """
  def next_state(state, opts \\ [])
  def next_state({width_po2, width, state}, opts) when width_po2>0 do
    # next_state_walker(width_po2, width, state)
    parts = split_state(width_po2, state)
    count = length(parts)

    new_state =
      parts
      |> Enum.chunk_every(div(count, 4)+1)
      |> Enum.map(&Task.async(fn -> next_state_parts(width_po2, count-1, width, state, &1) end))
      |> Task.yield_many(opts[:timeout] || 5000)
      |> Enum.map(&elem(elem(&1, 1), 1))
      |> List.flatten()
      |> Enum.sort(fn {l, _}, {r, _} -> l < r end)
      |> Enum.map(&elem(&1, 1))
      |> Enum.join()

    {width_po2, width, new_state}
  end


  defp split_state(width_po2, state, output \\ [], num \\ 0)
  defp split_state(_po2, <<>>, output, _num), do: output # Not reversing, performed later when sorted after tasking
  defp split_state(po2, state, out, num) do
    <<part::binary-size(po2), rest::binary>> = state
    split_state(po2, rest, [{num, part} | out], num+1)
  end


  defp next_state_parts(width_po2, bot, width, state, parts) do
    Enum.map(parts, fn
      {0, _part} = ret -> ret
      {^bot, _part} = ret -> ret
      {line, part} -> next_state_part(width_po2, width, state, line, part)
    end)
  end


  defp next_state_part(width_po2, width, state, line, part, output \\ "")
  # defp next_state_part(_width_po2, _width, _state, line, <<>>, output), do: {line, output}
  defp next_state_part(_width_po2, width, _state, line, part, output) when byte_size(output)>=width do
    {line, <<output::binary, part::binary>>}
  end
  defp next_state_part(width_po2, width, state, line, <<c, rest::binary>>, output) do
    c = next_state_value(width_po2, byte_size(output), line, state, c)
    next_state_part(width_po2, width, state, line, rest, <<output::binary, c>>)
  end


  defp next_state_value(width_po2, x, y, state, old_value)
  defp next_state_value(_width_po2, _x, _y, _state, @empt), do: @empt
  defp next_state_value(_width_po2, _x, _y, _state, @tail), do: @wire
  defp next_state_value(_width_po2, _x, _y, _state, @elec), do: @tail
  defp next_state_value(width_po2, x, y, state, @wire) do
    elec_neighbors =
      get_state_value_if_elec(width_po2, x-1, y-1, state) +
      get_state_value_if_elec(width_po2, x-1, y  , state) +
      get_state_value_if_elec(width_po2, x-1, y+1, state) +
      get_state_value_if_elec(width_po2, x, y-1  , state) +
      get_state_value_if_elec(width_po2, x, y+1  , state) +
      get_state_value_if_elec(width_po2, x+1, y-1, state) +
      get_state_value_if_elec(width_po2, x+1, y  , state) +
      get_state_value_if_elec(width_po2, x+1, y+1, state)

    case elec_neighbors do
      1 -> @elec
      2 -> @elec
      _ -> @wire
    end
  end


  defp get_state_value_if_elec(width_po2, x, y, state) do
    skipped = (y*width_po2) + x
    <<_::binary-size(skipped), v, _::binary>> = state
    if v >= @elec, do: 1, else: 0
  end


  @doc ~S"""
  Run a demo, valid types are:

  * :nullifer -> Shows a nullifier circuit to prevent passing signal
  * :diodes -> Shows two diodes with signals in opposite directions and how they allow/prevent flow
  * :Clocks_xor -> Shows two clocks feeding an xor

  Opts can contain:

  * `colorized: true` to enable colorized output
  * `count: 25` to set how many iterations to perform
  * `speed: 250` to set the sleep in milliseconds between each iteration

  """
  def demo(type \\ :nullifier, opts \\ []) do
    circuit =
      case type do
        :nullifier ->
          ~S"""
          tH.........
          .   .
             ...
          .   .
          Ht.. ......
          """
        :diodes ->
          ~S"""
          .     ..
          tH..... ......
                ..

          .     ..
          tH.... .......
                ..
          """
        :clocks_xor ->
          ~S"""
           tH....tH
          .        ......
           ........      .
                        ....
                        .  .....
                        ....
           tH......      .
          .        ......
           ...Ht...
          """
      end
    count = opts[:count] || 25
    speed = opts[:speed] || 250
    colorized = opts[:colorized] || false
    state = setup(:lines, circuit)
    Enum.reduce(0..count, state, fn _, state ->
      IO.puts("\n"<>Wireworld.to_string(state, colorized: colorized))
      Process.sleep(speed)
      next_state(state)
    end)
  end
end
