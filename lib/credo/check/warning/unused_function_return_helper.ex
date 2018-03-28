defmodule Credo.Check.Warning.UnusedFunctionReturnHelper do
  @moduledoc """
  TODO v1.0:
  should complain about calls in blocks, where the call ...

  * is NOT assigned to a variable
  * is NOT the last call in the block (i.e. the return value)
  * is NOT piped into another function
  * is NOT an argument to another function call

  safe cases (no issue):

  the call ...
  * is directly assigned to a variable
  * is the last call in a function
  * is piped into another function
  * is an argument to another function call

  trickier cases:

  the call ...
  * is the last call in a block, but that block is part of an :if which is
    * not the last call in its function and also
    * not assigned to a variable and
    * not piped into another function
  """

  @def_ops [:def, :defp, :defmacro]
  @block_ops [:if, :unless, :case, :quote, :try, :after, :rescue]

  alias Credo.Check.CodeHelper
  alias Credo.SourceFile

  def find_unused_calls(
        %SourceFile{} = source_file,
        _params,
        required_mod_list,
        restrict_fun_names
      ) do
    Credo.Code.prewalk(
      source_file,
      &traverse(&1, &2, source_file, required_mod_list, restrict_fun_names)
    )
  end

  for op <- @def_ops do
    defp traverse(
           {unquote(op), _meta, arguments} = ast,
           all_unused_calls,
           _source_file,
           required_mod_list,
           restrict_fun_names
         )
         when is_list(arguments) do
      # should complain when a call to mod is found inside the function body
      #
      # - that is not part of :=
      # - that is not piped into another function
      # - that is not the return value
      #
      # In turn this means
      # - the last call in the function can contain a mod call
      # - any := can contain a mod calls_in_function
      # - any pipe chain can contain a mod call, as long as it is not the
      #   last call in the chain
      calls_in_function = CodeHelper.calls_in_do_block(ast)
      last_call_in_def = List.last(calls_in_function)

      all_unused_calls =
        all_unused_calls ++
          Enum.flat_map(
            calls_in_function,
            &invalid_calls(
              &1,
              last_call_in_def,
              calls_in_function,
              required_mod_list,
              restrict_fun_names
            )
          )

      # IO.puts(IO.ANSI.format([:yellow, "OP:", unquote(op) |> to_string]))
      # IO.inspect(ast |> CodeHelper.do_block_for())
      # IO.inspect(calls_in_function)
      # IO.inspect(last_call_in_def)
      # IO.puts("")

      {ast, all_unused_calls}
    end
  end

  defp traverse(ast, all_unused_calls, _source_file, _required_mod_list, _restrict_fun_names) do
    {ast, all_unused_calls}
  end

  defp invalid_calls(
         call,
         last_call_in_def,
         calls_in_block_above,
         required_mod_list,
         restrict_fun_names
       ) do
    if CodeHelper.do_block?(call) do
      # IO.inspect("do block")
      # |> IO.inspect
      call
      |> calls_to_mod_fun(required_mod_list, restrict_fun_names)
      |> Enum.reject(
        &valid_call_to_fun_mod?(
          call,
          &1,
          last_call_in_def,
          calls_in_block_above
        )
      )
    else
      # IO.inspect("no do block")
      # IO.inspect(call)

      if call == last_call_in_def do
        []
      else
        call
        |> calls_to_mod_fun(required_mod_list, restrict_fun_names)
        |> Enum.reject(
          &valid_call_to_fun_mod?(
            call,
            &1,
            last_call_in_def,
            calls_in_block_above
          )
        )
      end
    end
  end

  defp valid_call_to_fun_mod?(
         {:=, _, _} = ast,
         call_to_mod,
         _last_call_in_def,
         _calls_in_block_above
       ) do
    CodeHelper.contains_child?(ast, call_to_mod)
  end

  for op <- @block_ops do
    defp valid_call_to_fun_mod?(
           {unquote(op), _meta, arguments} = ast,
           call_to_mod,
           last_call_in_def,
           calls_in_block_above
         )
         when is_list(arguments) do
      condition = List.first(arguments)

      if CodeHelper.contains_child?(condition, call_to_mod) do
        true
      else
        [
          CodeHelper.do_block_for!(arguments),
          CodeHelper.else_block_for!(arguments)
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.any?(
          &valid_call_to_fun_mod_in_block?(
            &1,
            ast,
            call_to_mod,
            last_call_in_def,
            calls_in_block_above
          )
        )
      end
    end
  end

  defp valid_call_to_fun_mod?(
         {:for, _meta, arguments} = ast,
         call_to_mod,
         last_call_in_def,
         calls_in_block_above
       )
       when is_list(arguments) do
    arguments_without_do_block = Enum.slice(arguments, 0..-2)

    if CodeHelper.contains_child?(arguments_without_do_block, call_to_mod) do
      true
    else
      [
        CodeHelper.do_block_for!(arguments),
        CodeHelper.else_block_for!(arguments)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.any?(
        &valid_call_to_fun_mod_in_block?(
          &1,
          ast,
          call_to_mod,
          last_call_in_def,
          calls_in_block_above
        )
      )
    end
  end

  defp valid_call_to_fun_mod?(
         {:cond, _meta, arguments} = ast,
         call_to_mod,
         last_call_in_def,
         calls_in_block_above
       ) do
    [
      CodeHelper.do_block_for!(arguments),
      CodeHelper.else_block_for!(arguments)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.any?(
      &valid_call_to_fun_mod_in_block?(
        &1,
        ast,
        call_to_mod,
        last_call_in_def,
        calls_in_block_above
      )
    )
  end

  defp valid_call_to_fun_mod?(
         {:__block__, _meta, arguments},
         call_to_mod,
         last_call_in_def,
         calls_in_block_above
       ) do
    # IO.puts(IO.ANSI.format([:yellow, ":__block__"]))

    arguments
    |> List.wrap()
    |> Enum.any?(
      &valid_call_to_fun_mod?(
        &1,
        call_to_mod,
        last_call_in_def,
        calls_in_block_above
      )
    )
  end

  defp valid_call_to_fun_mod?(
         {:fn, _meta, arguments},
         call_to_mod,
         last_call_in_def,
         calls_in_block_above
       ) do
    # IO.puts(IO.ANSI.format([:yellow, ":fn"]))

    arguments
    |> List.wrap()
    |> Enum.any?(
      &valid_call_to_fun_mod?(
        &1,
        call_to_mod,
        last_call_in_def,
        calls_in_block_above
      )
    )
  end

  defp valid_call_to_fun_mod?(
         {:->, _meta, [params, arguments]} = ast,
         call_to_mod,
         last_call_in_def,
         calls_in_block_above
       ) do
    # IO.puts(IO.ANSI.format([:yellow, ":->"]))
    # IO.inspect(arguments, label: "arguments")
    # IO.inspect(call_to_mod, label: "call_to_mod")
    # IO.inspect(CodeHelper.contains_child?(params, call_to_mod))
    # IO.puts("")

    if CodeHelper.contains_child?(params, call_to_mod) do
      true
    else
      calls_in_this_block = List.wrap(arguments)
      block_is_last_call_in_def? = CodeHelper.contains_child?(last_call_in_def, ast)
      call_to_mod_is_last_call_in_this_block? = call_to_mod == List.last(calls_in_this_block)

      if block_is_last_call_in_def? && call_to_mod_is_last_call_in_this_block? do
        true
      else
        Enum.any?(
          calls_in_this_block,
          &valid_call_to_fun_mod?(
            &1,
            call_to_mod,
            last_call_in_def,
            calls_in_block_above
          )
        )
      end
    end
  end

  defp valid_call_to_fun_mod?(
         {:|>, _, arguments} = ast,
         call_to_mod,
         last_call_in_def,
         _calls_in_block_above
       ) do
    # IO.puts(IO.ANSI.format([:yellow, ":|>"]))
    # We are in a pipe chain that is NOT the last call in the function
    # and that is NOT part of an assignment.
    # This is fine, as long as the call to mod is not the last element
    # in the pipe chain.
    if CodeHelper.contains_child?(last_call_in_def, ast) &&
         CodeHelper.contains_child?(ast, call_to_mod) do
      true
    else
      List.last(arguments) != call_to_mod
    end
  end

  defp valid_call_to_fun_mod?(
         {:++, _, _arguments} = ast,
         call_to_mod,
         last_call_in_def,
         _calls_in_block_above
       ) do
    # IO.puts(IO.ANSI.format([:yellow, ":++"]))

    CodeHelper.contains_child?(last_call_in_def, ast) &&
      CodeHelper.contains_child?(ast, call_to_mod)
  end

  defp valid_call_to_fun_mod?(
         {_atom, _meta, arguments} = ast,
         call_to_mod,
         last_call_in_def,
         calls_in_block_above
       ) do
    fns = fn_in_arguments(ast)

    if Enum.any?(fns) && Enum.any?(fns, &CodeHelper.contains_child?(&1, call_to_mod)) do
      # IO.puts(IO.ANSI.format([:red, "Last fn"]))
      # IO.inspect(ast)

      Enum.any?(
        fns,
        &valid_call_to_fun_mod?(
          &1,
          call_to_mod,
          last_call_in_def,
          calls_in_block_above
        )
      )
    else
      # IO.puts(IO.ANSI.format([:red, "Last"]))
      # IO.puts(IO.ANSI.format([:cyan, Macro.to_string(call_to_mod)]))
      # IO.inspect(ast)
      # IO.inspect(calls_in_block_above)
      # IO.puts("")

      # result =
      #  CodeHelper.contains_child?(last_call_in_def, ast) &&
      #    CodeHelper.contains_child?(ast, call_to_mod) &&
      #      call_to_mod == calls_in_block_above |> List.last

      # IO.inspect(
      #   {:result, CodeHelper.contains_child?(last_call_in_def, ast),
      #    CodeHelper.contains_child?(call_to_mod, ast),
      #    CodeHelper.contains_child?(calls_in_block_above |> List.last(), call_to_mod)}
      # )

      in_call_to_mod_and_last_call? =
        CodeHelper.contains_child?(last_call_in_def, ast) &&
          CodeHelper.contains_child?(call_to_mod, ast) &&
          CodeHelper.contains_child?(
            List.last(calls_in_block_above),
            call_to_mod
          )

      containing_call_to_mod? = CodeHelper.contains_child?(arguments, call_to_mod)

      # IO.inspect(CodeHelper.contains_child?(arguments, call_to_mod))
      # IO.puts("")

      in_call_to_mod_and_last_call? || containing_call_to_mod?
    end
  end

  defp valid_call_to_fun_mod?(
         tuple,
         call_to_mod,
         last_call_in_def,
         calls_in_block_above
       )
       when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.any?(
      &valid_call_to_fun_mod?(
        &1,
        call_to_mod,
        last_call_in_def,
        calls_in_block_above
      )
    )
  end

  defp valid_call_to_fun_mod?(
         list,
         call_to_mod,
         last_call_in_def,
         calls_in_block_above
       )
       when is_list(list) do
    Enum.any?(
      list,
      &valid_call_to_fun_mod?(
        &1,
        call_to_mod,
        last_call_in_def,
        calls_in_block_above
      )
    )
  end

  defp valid_call_to_fun_mod?(
         _ast,
         _call_to_mod,
         _last_call_in_def,
         _calls_in_block_above
       ) do
    # IO.inspect("fall-thru")
    # IO.inspect(ast)

    # IO.inspect(
    #   CodeHelper.contains_child?(last_call_in_def, ast) &&
    #     CodeHelper.contains_child?(ast, call_to_mod)
    # )

    # IO.puts("")
    false
  end

  defp valid_call_to_fun_mod_in_block?(
         {:__block__, _meta, calls_in_this_block},
         _ast,
         call_to_mod,
         last_call_in_def,
         _calls_in_block_above
       ) do
    # IO.puts(IO.ANSI.format([:green, "Block separation (__block__)!"]))
    # IO.inspect(CodeHelper.contains_child?(last_call_in_def, ast))
    # IO.puts("")

    Enum.any?(
      calls_in_this_block,
      &valid_call_to_fun_mod?(
        &1,
        call_to_mod,
        last_call_in_def,
        calls_in_this_block
      )
    )
  end

  defp valid_call_to_fun_mod_in_block?(
         any_value,
         ast,
         call_to_mod,
         last_call_in_def,
         _calls_in_block_above
       ) do
    # IO.puts(IO.ANSI.format([:green, "Block separation (any_value)!"]))
    # IO.inspect(any_value)
    # IO.puts("")

    if CodeHelper.contains_child?(last_call_in_def, ast) &&
         CodeHelper.contains_child?(any_value, call_to_mod) do
      true
    else
      calls_in_this_block = List.wrap(any_value)

      Enum.any?(
        calls_in_this_block,
        &valid_call_to_fun_mod?(
          &1,
          call_to_mod,
          last_call_in_def,
          calls_in_this_block
        )
      )
    end
  end

  defp calls_to_mod_fun(ast, required_mod_list, restrict_fun_names) do
    {_, calls_to_mod} =
      Macro.postwalk(
        ast,
        [],
        &find_calls_to_mod_fun(&1, &2, required_mod_list, restrict_fun_names)
      )

    calls_to_mod
  end

  defp find_calls_to_mod_fun(
         {{:., _, [{:__aliases__, _, mod_list}, fun_atom]}, _, params} = ast,
         accumulated,
         required_mod_list,
         restrict_fun_names
       )
       when is_atom(fun_atom) and is_list(params) do
    if mod_list == required_mod_list do
      fun_names = List.wrap(restrict_fun_names)

      if Enum.empty?(fun_names) do
        {ast, accumulated ++ [ast]}
      else
        if Enum.member?(fun_names, fun_atom) do
          {ast, accumulated ++ [ast]}
        else
          {ast, accumulated}
        end
      end
    else
      {ast, accumulated}
    end
  end

  defp find_calls_to_mod_fun(ast, accumulated, _, _) do
    {ast, accumulated}
  end

  defp fn_in_arguments({_atom, _meta, arguments}) do
    arguments
    |> List.wrap()
    |> Enum.filter(fn arg ->
      case arg do
        {:fn, _, _} -> true
        _ -> false
      end
    end)
  end
end
