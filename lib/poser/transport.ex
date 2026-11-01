defmodule Poser.Transport do
  @moduledoc """
  Carries length-prefixed ETF frames between the client and the add-on.

  The handshake is done passively with `recv_frame/2`; after `activate/1`,
  frames arrive as messages to the owning process, which hands each one to
  `handle_message/2`.
  """

  @type conn :: term()

  @callback connect(host :: String.t(), port :: pos_integer(), timeout()) ::
              {:ok, conn()} | {:error, term()}
  @callback send_frame(conn(), iodata()) :: :ok | {:error, term()}
  @callback recv_frame(conn(), timeout()) :: {:ok, binary()} | {:error, term()}
  @callback activate(conn()) :: :ok | {:error, term()}
  @callback handle_message(conn(), msg :: term()) ::
              {:frame, binary()} | {:closed, term()} | :ignore
  @callback close(conn()) :: :ok
end
