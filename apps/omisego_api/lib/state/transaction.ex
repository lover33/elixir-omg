defmodule OmiseGO.API.State.Transaction do
  @moduledoc """
  Internal representation of a spend transaction on Plasma chain
  """

  alias OmiseGO.API.Crypto
  alias OmiseGO.API.State.Transaction.{Signed}

  @zero_address <<0::size(160)>>
  @max_inputs 2

  defstruct [
    :blknum1,
    :txindex1,
    :oindex1,
    :blknum2,
    :txindex2,
    :oindex2,
    :cur12,
    :newowner1,
    :amount1,
    :newowner2,
    :amount2,
    :fee
  ]

  @type t() :: %__MODULE__{
          blknum1: non_neg_integer(),
          txindex1: non_neg_integer(),
          oindex1: 0 | 1,
          blknum2: non_neg_integer(),
          txindex2: non_neg_integer(),
          oindex2: 0 | 1,
          cur12: Crypto.address_t(),
          newowner1: Crypto.address_t(),
          amount1: pos_integer(),
          newowner2: Crypto.address_t(),
          amount2: non_neg_integer(),
          fee: non_neg_integer()
        }

  def create_from_utxos(%{utxos: utxos}, _, _) when length(utxos) > @max_inputs,
    do: {:error, :too_many_utxo}

  def create_from_utxos(%{utxos: utxos} = inputs, receiver, fee) do
    with {:ok, cur1} <- validate_currency(utxos) do
      do_create_from_utxos(inputs, cur1, receiver, fee)
    end
  end

  defp do_create_from_utxos(
         %{address: change_address, utxos: utxos},
         cur1,
         %{address: receiver_address, amount: amount},
         fee
       ) do
    parts_transaction =
      utxos
      |> Enum.with_index(1)
      |> Enum.map(fn {utxo, number} ->
        %{
          String.to_existing_atom("blknum#{number}") => utxo.blknum,
          String.to_existing_atom("txindex#{number}") => utxo.txindex,
          String.to_existing_atom("oindex#{number}") => utxo.oindex,
          amount: utxo.amount
        }
      end)

    all_amount = Enum.reduce(parts_transaction, 0, &(&1.amount + &2))

    transaction =
      Enum.reduce(parts_transaction, %{cur12: cur1}, fn part_transaction, acc ->
        {_, part_transaction} = Map.pop(part_transaction, :amount)
        Map.merge(acc, part_transaction)
      end)

    transaction =
      struct!(
        __MODULE__,
        Map.merge(transaction, %{
          newowner1: receiver_address,
          amount1: amount,
          newowner2: change_address,
          amount2: all_amount - amount - fee,
          fee: fee
        })
      )

    case validate(transaction) do
      :ok -> {:ok, transaction}
      {:error, _} = error -> error
    end
  end

  defp validate_currency([%{currency: cur1}, %{currency: cur2}]) when cur1 != cur2 do
    {:error, :currency_mixing_not_possible}
  end

  defp validate_currency([%{currency: cur1} | _]) do
    {:ok, cur1}
  end

  defp validate(%__MODULE__{} = transaction) do
    cond do
      transaction.amount1 < 0 -> {:error, :amount_negative_value}
      transaction.amount2 < 0 -> {:error, :amount_negative_value}
      transaction.fee < 0 -> {:error, :fee_negative_value}
      true -> :ok
    end
  end

  @doc """
   assumptions:
     length(inputs) <= @number_of_transaction
     length(outputs) <= @number_of_transaction
   behavior:
      Adjusts the inputs and outputs for each transaction with empty ones
      to match the expected size of @number_of_transaction. Then adds the fee.
       for inputs add {0, 0, 0} where {blknum, txindex, oindex}
       for outpust add {0, 0} where {newowner, amount}
  """
  @spec new(
          list({pos_integer, pos_integer, 0 | 1}),
          Crypto.address_t(),
          list({Crypto.address_t(), pos_integer}),
          pos_integer
        ) :: t()
  def new(inputs, currency, outputs, fee) do
    inputs = inputs ++ List.duplicate({0, 0, 0}, @max_inputs - Kernel.length(inputs))
    outputs = outputs ++ List.duplicate({0, 0}, @max_inputs - Kernel.length(outputs))

    inputs =
      inputs
      |> Enum.with_index(1)
      |> Enum.map(fn {{blknum, txindex, oindex}, index} ->
        %{
          String.to_existing_atom("blknum#{index}") => blknum,
          String.to_existing_atom("txindex#{index}") => txindex,
          String.to_existing_atom("oindex#{index}") => oindex
        }
      end)
      |> Enum.reduce(%{}, &Map.merge/2)

    outputs =
      outputs
      |> Enum.with_index(1)
      |> Enum.map(fn {{newowner, amount}, index} ->
        %{
          String.to_existing_atom("newowner#{index}") => newowner,
          String.to_existing_atom("amount#{index}") => amount
        }
      end)
      |> Enum.reduce(%{cur12: currency}, &Map.merge/2)

    struct(__MODULE__, Map.put(Map.merge(inputs, outputs), :fee, fee))
  end

  def zero_address, do: @zero_address

  def account_address?(@zero_address), do: false
  def account_address?(address) when is_binary(address) and byte_size(address) == 20, do: true
  def account_address?(_), do: false

  def encode(%__MODULE__{} = tx) do
    [
      tx.blknum1,
      tx.txindex1,
      tx.oindex1,
      tx.blknum2,
      tx.txindex2,
      tx.oindex2,
      tx.cur12,
      tx.newowner1,
      tx.amount1,
      tx.newowner2,
      tx.amount2,
      tx.fee
    ]
    |> ExRLP.encode()
  end

  def hash(%__MODULE__{} = tx) do
    tx
    |> encode
    |> Crypto.hash()
  end

  @doc """
    private keys are in the form: <<54, 43, 207, 67, 140, 160, 190, 135, 18, 162, 70, 120, 36, 245, 106, 165, 5, 101, 183,
      55, 11, 117, 126, 135, 49, 50, 12, 228, 173, 219, 183, 175>>
  """
  @spec sign(t(), Crypto.priv_key_t(), Crypto.priv_key_t()) :: Signed.t()
  def sign(%__MODULE__{} = tx, priv1, priv2) do
    encoded_tx = encode(tx)
    signature1 = signature(encoded_tx, priv1)
    signature2 = signature(encoded_tx, priv2)

    %Signed{raw_tx: tx, sig1: signature1, sig2: signature2, signed_tx_bytes: nil}
  end

  defp signature(_encoded_tx, <<>>), do: <<0::size(520)>>
  defp signature(encoded_tx, priv), do: Crypto.signature(encoded_tx, priv)
end
