defmodule Muex.MutantOptimizerTest do
  use ExUnit.Case, async: true

  alias Muex.Config
  alias Muex.Mutator
  alias Muex.MutantOptimizer
  alias Muex.Mutator.Arithmetic

  # The default optimizer options produced by `--optimize-level balanced`.
  @balanced [
    enabled: true,
    min_complexity: 2,
    max_mutations_per_function: 20,
    cluster_similarity_threshold: 0.8,
    keep_boundary_mutations: true
  ]

  defp mutations_for(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    Mutator.walk(ast, Config.all_mutators(), %{file: "lib/sample.ex"})
  end

  defp mutator_names(mutations) do
    mutations |> Enum.map(&module_name(&1.mutator)) |> Enum.uniq()
  end

  defp module_name(mod), do: mod |> Module.split() |> List.last()

  describe "optimize/2 with default 'balanced' options" do
    test "keeps arithmetic and comparison mutants inside a non-trivial function" do
      source = """
      defmodule Sample do
        def total(qty, unit) do
          subtotal = qty * unit
          if subtotal > 100, do: subtotal - 10, else: subtotal + 5
        end
      end
      """

      optimized = source |> mutations_for() |> MutantOptimizer.optimize(@balanced)

      # Regression guard: complexity is judged from the enclosing function, not
      # the detached fragment. Before this fix every arithmetic/comparison/
      # literal/function-call fragment scored complexity 1 and was filtered out,
      # leaving the run with effectively no mutants for those operators.
      refute optimized == []
      names = mutator_names(optimized)
      assert "Arithmetic" in names
      assert "Comparison" in names
    end

    test "retains the boundary comparison despite the lossy filter stages" do
      source = """
      defmodule Sample do
        def at_least?(value, limit) do
          if value >= limit, do: :ok, else: :too_low
        end
      end
      """

      optimized = source |> mutations_for() |> MutantOptimizer.optimize(@balanced)

      # A mutation of the `>=` boundary operator survives (before the fix the
      # whole-fragment complexity filter dropped it despite keep_boundary).
      assert Enum.any?(optimized, fn m ->
               module_name(m.mutator) == "Comparison" and match?({:>=, _, _}, m.original_ast)
             end)
    end

    test "still filters mutants in a trivial single-operation function" do
      # The optimizer is intentionally designed to skip getters and one-liners,
      # so a function with no branching keeps that behavior.
      optimized =
        "defmodule S do\n  def add(a, b), do: a + b\nend"
        |> mutations_for()
        |> MutantOptimizer.optimize(@balanced)

      refute "Arithmetic" in mutator_names(optimized)
    end
  end

  describe "complexity is judged from the enclosing function, not the fragment" do
    test "walk/3 attaches the enclosing function definition as :context_ast" do
      [mutation | _] =
        "defmodule S do\n  def f(a, b), do: a + b\nend"
        |> mutations_for()
        |> Enum.filter(&(module_name(&1.mutator) == "Arithmetic"))

      assert %{context_ast: {:def, _, _}} = mutation
    end

    test "filter_by_complexity keeps a simple fragment when its function is complex" do
      bare = %{
        ast: {:+, [line: 2], [{:a, [], nil}, {:b, [], nil}]},
        mutator: Arithmetic,
        location: %{file: "lib/x.ex", line: 2}
      }

      # On its own the fragment has no decision points -> complexity 1 -> dropped.
      assert MutantOptimizer.filter_by_complexity([bare], 2) == []

      {:ok, fun_ast} =
        Code.string_to_quoted("def f(a, b) do\n  if a, do: a + b, else: b\nend")

      # Once the enclosing (branching) function is known, it is kept.
      with_context = Map.put(bare, :context_ast, fun_ast)
      assert [%{context_ast: _}] = MutantOptimizer.filter_by_complexity([with_context], 2)
    end
  end
end
