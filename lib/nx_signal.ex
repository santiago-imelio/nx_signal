defmodule NxSignal do
  @moduledoc """
  Nx library extension for DSP
  """

  import Nx.Defn

  @doc ~S"""
  Computes the Short-Time Fourier Transform of a tensor.

  Returns the complex spectrum Z, the time in seconds for
  each frame and the frequency bins in Hz.

  The STFT is parameterized through:

    * $k$: length of the Discrete Fourier Transform (DFT)
    * $N$: length of each frame
    * $H$: hop (in samples) between frames (calculated as $H = N - \text{overlap\\_length}$)
    * $M$: number of frames
    * $x[n]$: the input time-domain signal
    * $w[n]$: the window function to be applied to each frame

  $$
  DFT(x, w) := \sum_{n=0}^{N - 1} x[n]w[n]e^\frac{-2 \pi i k n}{N} \\\\
  X[m, k] = DFT(x[mH..(mH + N - 1)], w)
  $$

  where $m$ assumes all values in the interval $[0, M - 1]$

  See also: `NxSignal.Windows`, `istft/3`

  ## Options

    * `:sampling_rate` - the sampling frequency $F_s$ for the input in Hz. Defaults to `1000`.
    * `:fft_length` - the DFT length that will be passed to `Nx.fft/2`. Defaults to `:power_of_two`.
    * `:overlap_length` - the number of samples for the overlap between frames.
      Defaults to half the window size.
    * `:window_padding` - `:reflect`, `:zeros` or `nil`. See `as_windowed/3` for more details.
    * `:scaling` - `nil`, `:spectrum` or `:psd`.
      * `:spectrum` - each frame is divided by $\sum_{i} window[i]$.
      * `nil` - No scaling is applied.
      * `:psd` - each frame is divided by $\sqrt{F\_s\sum_{i} window[i]^2}$.

  ## Examples

      iex> {z, t, f} = NxSignal.stft(Nx.iota({4}), NxSignal.Windows.rectangular(n: 2), overlap_length: 1, fft_length: 2, sampling_rate: 400)
      iex> z
      #Nx.Tensor<
        c64[frames: 3][frequencies: 2]
        [
          [1.0+0.0i, -1.0+0.0i],
          [3.0+0.0i, -1.0+0.0i],
          [5.0+0.0i, -1.0+0.0i]
        ]
      >
      iex> t
      #Nx.Tensor<
        f32[frames: 3]
        [0.0024999999441206455, 0.004999999888241291, 0.007499999832361937]
      >
      iex> f
      #Nx.Tensor<
        f32[frequencies: 2]
        [0.0, 200.0]
      >
  """
  @doc type: :time_frequency
  deftransform stft(data, window, opts \\ []) do
    {frame_length} = Nx.shape(window)

    opts =
      Keyword.validate!(opts, [
        :overlap_length,
        :window,
        :scaling,
        window_padding: :valid,
        sampling_rate: 100,
        fft_length: :power_of_two
      ])

    sampling_rate = opts[:sampling_rate] || raise ArgumentError, "missing sampling_rate option"

    overlap_length = opts[:overlap_length] || div(frame_length, 2)

    stft_n(data, window, sampling_rate, Keyword.put(opts, :overlap_length, overlap_length))
  end

  defnp stft_n(data, window, sampling_rate, opts \\ []) do
    {frame_length} = Nx.shape(window)
    padding = opts[:window_padding]
    fft_length = opts[:fft_length]
    overlap_length = opts[:overlap_length]

    spectrum =
      data
      |> as_windowed(
        padding: padding,
        window_length: frame_length,
        stride: frame_length - overlap_length
      )
      |> Nx.multiply(window)
      |> Nx.fft(length: fft_length)

    {num_frames, fft_length} = Nx.shape(spectrum)

    frequencies = fft_frequencies(sampling_rate, fft_length: fft_length)

    # assign the middle of the equivalent time window as the time for the given frame
    time_step = frame_length / (2 * sampling_rate)
    last_frame = time_step * num_frames
    times = Nx.linspace(time_step, last_frame, n: num_frames, name: :frames)

    output =
      case opts[:scaling] do
        :spectrum ->
          spectrum / Nx.sum(window)

        :psd ->
          spectrum / Nx.sqrt(sampling_rate * Nx.sum(window ** 2))

        nil ->
          spectrum

        scaling ->
          raise ArgumentError,
                "invalid :scaling, expected one of :spectrum, :psd or nil, got: #{inspect(scaling)}"
      end

    {Nx.reshape(output, spectrum.shape, names: [:frames, :frequencies]), times, frequencies}
  end

  @doc """
  Computes the frequency bins for a FFT with given options.

  ## Arguments

    * `sampling_rate` - Sampling frequency in Hz.

  ## Options

    * `:fft_length` - Number of FFT frequency bins.
    * `:type` - Optional output type. Defaults to `{:f, 32}`
    * `:name` - Optional axis name for the tensor. Defaults to `:frequencies`

  ## Examples

      iex> NxSignal.fft_frequencies(1.6e4, fft_length: 10)
      #Nx.Tensor<
        f32[frequencies: 10]
        [0.0, 1.6e3, 3.2e3, 4.8e3, 6.4e3, 8.0e3, 9.6e3, 1.12e4, 1.28e4, 1.44e4]
      >
  """
  @doc type: :time_frequency
  defn fft_frequencies(sampling_rate, opts \\ []) do
    opts = keyword!(opts, [:fft_length, type: {:f, 32}, name: :frequencies, endpoint: false])
    fft_length = opts[:fft_length]

    step = sampling_rate / fft_length

    Nx.linspace(0, step * fft_length,
      n: fft_length,
      type: opts[:type],
      name: opts[:name],
      endpoint: opts[:endpoint]
    )
  end

  @doc """
  Returns a tensor of K windows of length N

  ## Options

    * `:window_length` - the number of samples in a window
    * `:stride` - The number of samples to skip between windows. Defaults to `1`.
    * `:padding` - A can be `:reflect` or a valid padding as per `Nx.pad/3` over the
      input tensor's shape. Defaults to `:valid`. If `:reflect` or `:zeros`, the first window will be centered
      at the start of the signal. For `:reflect`, each incomplete window will be reflected as if it was
      periodic (see examples for `as_windowed/2`). For `:zeros`, each incomplete window will be zero-padded.

  ## Examples

      iex> NxSignal.as_windowed(Nx.tensor([0, 1, 2, 3, 4, 10, 11, 12]), window_length: 4)
      #Nx.Tensor<
        s64[5][4]
        [
          [0, 1, 2, 3],
          [1, 2, 3, 4],
          [2, 3, 4, 10],
          [3, 4, 10, 11],
          [4, 10, 11, 12]
        ]
      >

      iex> NxSignal.as_windowed(Nx.tensor([0, 1, 2, 3, 4, 10, 11, 12]), window_length: 3)
      #Nx.Tensor<
        s64[6][3]
        [
          [0, 1, 2],
          [1, 2, 3],
          [2, 3, 4],
          [3, 4, 10],
          [4, 10, 11],
          [10, 11, 12]
        ]
      >

      iex> NxSignal.as_windowed(Nx.tensor([0, 1, 2, 3, 4, 10, 11]), window_length: 2, stride: 2, padding: [{0, 3}])
      #Nx.Tensor<
        s64[5][2]
        [
          [0, 1],
          [2, 3],
          [4, 10],
          [11, 0],
          [0, 0]
        ]
      >

      iex> t = Nx.iota({7});
      iex> NxSignal.as_windowed(t, window_length: 6, padding: :reflect, stride: 1)
      #Nx.Tensor<
        s64[7][6]
        [
          [1, 2, 1, 0, 1, 2],
          [2, 1, 0, 1, 2, 3],
          [1, 0, 1, 2, 3, 4],
          [0, 1, 2, 3, 4, 5],
          [1, 2, 3, 4, 5, 6],
          [2, 3, 4, 5, 6, 5],
          [3, 4, 5, 6, 5, 4]
        ]
      >

      iex> NxSignal.as_windowed(Nx.iota({10}), window_length: 6, padding: :reflect, stride: 2)
      #Nx.Tensor<
        s64[5][6]
        [
          [1, 2, 1, 0, 1, 2],
          [1, 0, 1, 2, 3, 4],
          [1, 2, 3, 4, 5, 6],
          [3, 4, 5, 6, 7, 8],
          [5, 6, 7, 8, 9, 8]
        ]
      >
  """
  @doc type: :windowing
  deftransform as_windowed(tensor, opts \\ []) do
    if opts[:padding] == :reflect do
      as_windowed_reflect_padding(tensor, opts)
    else
      as_windowed_non_reflect_padding(tensor, opts)
    end
  end

  deftransformp as_windowed_parse_opts(shape, opts, :reflect) do
    window_length = opts[:window_length]

    as_windowed_parse_opts(
      shape,
      Keyword.put(opts, :padding, [{div(window_length, 2), div(window_length, 2) - 1}])
    )
  end

  deftransformp as_windowed_parse_opts(shape, opts) do
    opts = Keyword.validate!(opts, [:window_length, padding: :valid, stride: 1])
    window_length = opts[:window_length]
    window_dimensions = {window_length}

    padding = opts[:padding]

    [stride] =
      strides =
      case opts[:stride] do
        stride when is_list(stride) ->
          stride

        stride when is_integer(stride) and stride >= 1 ->
          [stride]

        stride ->
          raise ArgumentError,
                "expected an integer >= 1 or a list of integers, got: #{inspect(stride)}"
      end

    padding_config = as_windowed_to_padding_config(shape, window_dimensions, padding)

    # trick so that we can get Nx to calculate the pooled shape for us
    %{shape: pooled_shape} =
      Nx.window_max(
        Nx.iota(shape, backend: Nx.Defn.Expr),
        window_dimensions,
        padding: padding,
        strides: strides
      )

    output_shape = {Tuple.product(pooled_shape), window_length}

    {window_length, stride, padding_config, output_shape}
  end

  defp as_windowed_to_padding_config(shape, kernel_size, mode) do
    case mode do
      :valid ->
        List.duplicate({0, 0, 0}, tuple_size(shape))

      :same ->
        Enum.zip_with(Tuple.to_list(shape), Tuple.to_list(kernel_size), fn dim, k ->
          padding_size = max(dim - 1 + k - dim, 0)
          {floor(padding_size / 2), ceil(padding_size / 2), 0}
        end)

      config when is_list(config) ->
        Enum.map(config, fn
          {x, y} when is_integer(x) and is_integer(y) ->
            {x, y, 0}

          _other ->
            raise ArgumentError,
                  "padding must be a list of {high, low} tuples, where each element is an integer. " <>
                    "Got: #{inspect(config)}"
        end)

      mode ->
        raise ArgumentError,
              "invalid padding mode specified, padding must be one" <>
                " of :valid, :same, or a padding configuration, got:" <>
                " #{inspect(mode)}"
    end
  end

  defnp as_windowed_non_reflect_padding(tensor, opts \\ []) do
    # current implementation only supports windowing 1D tensors
    {window_length, stride, padding, output_shape} =
      as_windowed_parse_opts(Nx.shape(tensor), opts)

    output = Nx.broadcast(Nx.tensor(0, type: tensor.type), output_shape)
    {num_windows, _} = Nx.shape(output)

    index_template =
      Nx.concatenate([Nx.broadcast(0, {window_length, 1}), Nx.iota({window_length, 1})], axis: 1)

    {output, _, _, _, _} =
      while {output, i = 0, current_window = 0, t = Nx.pad(tensor, 0, padding), index_template},
            current_window < num_windows do
        indices = index_template + Nx.stack([current_window, 0])
        updates = t |> Nx.slice([i], [window_length]) |> Nx.flatten()

        updated = Nx.indexed_add(output, indices, updates)

        {updated, i + stride, current_window + 1, t, index_template}
      end

    output
  end

  defnp as_windowed_reflect_padding(tensor, opts \\ []) do
    # current implementation only supports windowing 1D tensors
    {window_length, stride, _padding, output_shape} =
      as_windowed_parse_opts(Nx.shape(tensor), opts, :reflect)

    output = Nx.broadcast(Nx.tensor(0, type: tensor.type), output_shape)
    {num_windows, _} = Nx.shape(output)

    index_template =
      Nx.concatenate([Nx.broadcast(0, {window_length, 1}), Nx.iota({window_length, 1})], axis: 1)

    leading_window_indices = generate_leading_window_indices(window_length, stride)

    trailing_window_indices =
      generate_trailing_window_indices(Nx.size(tensor), window_length, stride)

    half_window = div(window_length - 1, 2) + 1

    {output, _, _, _, _} =
      while {output, i = 0, current_window = 0, t = tensor, index_template},
            current_window < num_windows do
        # Here windows are centered at the current index

        cond do
          i < half_window ->
            # We're indexing before we have a full window on the left

            window = Nx.take(t, leading_window_indices[i])

            indices = index_template + Nx.stack([current_window, 0])
            updated = Nx.indexed_add(output, indices, window)

            {updated, i + stride, current_window + 1, t, index_template}

          i > Nx.size(t) - half_window ->
            # We're indexing after the last full window on the right
            window = Nx.take(t, trailing_window_indices[i - (Nx.size(t) - half_window + 1)])

            indices = index_template + Nx.stack([current_window, 0])
            updated = Nx.indexed_add(output, indices, window)

            {updated, i + stride, current_window + 1, t, index_template}

          true ->
            # Case where we can index a full window
            indices = index_template + Nx.stack([current_window, 0])
            updates = t |> Nx.slice([i - half_window], [window_length]) |> Nx.flatten()

            updated = Nx.indexed_add(output, indices, updates)

            {updated, i + stride, current_window + 1, t, index_template}
        end
      end

    # Now we need to handle the tail-end of the windows,
    # since they are currently all the same value. We want to apply the tapering-off
    # like we did with the initial windows.

    output
  end

  deftransformp generate_leading_window_indices(window_length, stride) do
    half_window = div(window_length, 2)

    for offset <- 0..half_window//stride do
      partial_length = offset + half_window
      padding_length = window_length - partial_length

      {partial_length}
      |> Nx.iota()
      |> Nx.reflect(padding_config: [{padding_length, 0}])
    end
    |> Nx.stack()
  end

  deftransformp generate_trailing_window_indices(tensor_size, window_length, stride) do
    min_index = tensor_size - window_length + 1

    for {offset, add} <- Enum.with_index(min_index..(tensor_size - 1)//stride) do
      partial_length = tensor_size - offset
      padding_length = window_length - partial_length

      {partial_length}
      |> Nx.iota()
      |> Nx.add(min_index + add - rem(window_length, 2))
      |> Nx.reflect(padding_config: [{0, padding_length}])
    end
    |> Nx.stack()
  end

  @doc """
  Generates weights for converting an STFT representation into MEL-scale.

  See also: `stft/3`, `istft/3`, `stft_to_mel/2`

  ## Arguments

    * `fft_length` - Number of FFT bins
    * `mel_bins` - Number of target MEL bins
    * `sampling_rate` - Sampling frequency in Hz

  ## Options
    * `:max_mel` - the pitch for the last MEL bin before log scaling. Defaults to 3016
    * `:mel_frequency_spacing` - the distance in Hz between two MEL bins before log scaling. Defaults to 66.6
    * `:type` - Target output type. Defaults to `{:f, 32}`

  ## Examples

      iex> NxSignal.mel_filters(10, 5, 8.0e3)
      #Nx.Tensor<
        f32[mels: 5][frequencies: 10]
        [
          [0.0, 8.129207999445498e-4, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
          [0.0, 9.972016559913754e-4, 2.1870288765057921e-4, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
          [0.0, 0.0, 9.510891977697611e-4, 4.150509194005281e-4, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
          [0.0, 0.0, 0.0, 4.035891906823963e-4, 5.276656011119485e-4, 2.574124082457274e-4, 0.0, 0.0, 0.0, 0.0],
          [0.0, 0.0, 0.0, 0.0, 7.329034269787371e-5, 2.342205698369071e-4, 3.8295105332508683e-4, 2.8712040511891246e-4, 1.9128978601656854e-4, 9.545915963826701e-5]
        ]
      >
  """
  @doc type: :time_frequency
  deftransform mel_filters(fft_length, mel_bins, sampling_rate, opts \\ []) do
    opts =
      Keyword.validate!(opts,
        max_mel: 3016,
        mel_frequency_spacing: 200 / 3,
        type: {:f, 32}
      )

    mel_filters_n(sampling_rate, opts[:max_mel], opts[:mel_frequency_spacing],
      type: opts[:type],
      fft_length: fft_length,
      mel_bins: mel_bins
    )
  end

  defnp mel_filters_n(sampling_rate, max_mel, f_sp, opts \\ []) do
    fft_length = opts[:fft_length]
    mel_bins = opts[:mel_bins]
    type = opts[:type]

    fftfreqs = fft_frequencies(sampling_rate, type: type, fft_length: fft_length)

    mels = Nx.linspace(0, max_mel / f_sp, type: type, n: mel_bins + 2, name: :mels)
    freqs = f_sp * mels

    min_log_hz = 1_000
    min_log_mel = min_log_hz / f_sp

    # numpy uses the f64 value by default
    logstep = Nx.log(6.4) / 27

    log_t = mels >= min_log_mel

    # This is the same as freqs[log_t] = min_log_hz * Nx.exp(logstep * (mels[log_t] - min_log_mel))
    # notice that since freqs and mels are indexed by the same conditional tensor, we don't
    # need to slice either of them
    mel_f = Nx.select(log_t, min_log_hz * Nx.exp(logstep * (mels - min_log_mel)), freqs)

    fdiff = Nx.new_axis(mel_f[1..-1//1] - mel_f[0..-2//1], 1)
    ramps = Nx.new_axis(mel_f, 1) - fftfreqs

    lower = -ramps[0..(mel_bins - 1)] / fdiff[0..(mel_bins - 1)]
    upper = ramps[2..(mel_bins + 1)//1] / fdiff[1..mel_bins]
    weights = Nx.max(0, Nx.min(lower, upper))

    enorm = 2.0 / (mel_f[2..(mel_bins + 1)] - mel_f[0..(mel_bins - 1)])

    weights * Nx.new_axis(enorm, 1)
  end

  @doc """
  Converts a given STFT time-frequency spectrum into a MEL-scale time-frequency spectrum.

  See also: `stft/3`, `istft/3`, `mel_filters/1`

  ## Arguments

    * `z` - STFT spectrum
    * `sampling_rate` - Sampling frequency in Hz

  ## Options

    * `:fft_length` - Number of FFT bins
    * `:mel_bins` - Number of target MEL bins. Defaults to 128
    * `:type` - Target output type. Defaults to `{:f, 32}`

  ## Examples

      iex> fft_length = 16
      iex> sampling_rate = 8.0e3
      iex> {z, _, _} = NxSignal.stft(Nx.iota({10}), NxSignal.Windows.hann(n: 4), overlap_length: 2, fft_length: fft_length, sampling_rate: sampling_rate, window_padding: :reflect)
      iex> Nx.axis_size(z, :frequencies)
      16
      iex> Nx.axis_size(z, :frames)
      5
      iex> NxSignal.stft_to_mel(z, sampling_rate, fft_length: fft_length, mel_bins: 4)
      #Nx.Tensor<
        f32[frames: 5][mel: 4]
        [
          [0.2900530695915222, 0.17422175407409668, 0.18422472476959229, 0.09807997941970825],
          [0.6093881130218506, 0.5647397041320801, 0.4353824257850647, 0.08635270595550537],
          [0.7584103345870972, 0.7085014581680298, 0.5636920928955078, 0.179118812084198],
          [0.8461772203445435, 0.7952491044998169, 0.6470762491226196, 0.2520409822463989],
          [0.908548891544342, 0.8572604656219482, 0.7078656554222107, 0.3086767792701721]
        ]
      >
  """
  @doc type: :time_frequency
  defn stft_to_mel(z, sampling_rate, opts \\ []) do
    opts =
      keyword!(opts, [:fft_length, :mel_bins, :max_mel, :mel_frequency_spacing, type: {:f, 32}])

    magnitudes = Nx.abs(z) ** 2

    filters =
      mel_filters(opts[:fft_length], opts[:mel_bins], sampling_rate, mel_filters_opts(opts))

    freq_size = div(opts[:fft_length], 2)

    real_freqs_mag = Nx.slice_along_axis(magnitudes, 0, freq_size, axis: :frequencies)
    real_freqs_filters = Nx.slice_along_axis(filters, 0, freq_size, axis: :frequencies)

    mel_spec =
      Nx.dot(
        real_freqs_mag,
        [:frequencies],
        real_freqs_filters,
        [:frequencies]
      )

    mel_spec = Nx.reshape(mel_spec, Nx.shape(mel_spec), names: [:frames, :mel])

    log_spec = Nx.log(Nx.clip(mel_spec, 1.0e-10, :infinity)) / Nx.log(10)
    log_spec = Nx.max(log_spec, Nx.reduce_max(log_spec) - 8)
    (log_spec + 4) / 4
  end

  deftransformp mel_filters_opts(opts) do
    Keyword.take(opts, [:max_mel, :mel_frequency_spacing, :type])
  end

  @doc """
  Computes the Inverse Short-Time Fourier Transform of a tensor.
  Returns a tensor of M time-domain frames of length `fft_length`.
  See also: `NxSignal.Windows`, `Nx.Signal.stft`

  ## Options

    * `:fft_length` - the DFT length that will be passed to `Nx.fft/2`. Defaults to `:power_of_two`.
    * `:overlap_length` - the number of samples for the overlap between frames.
      Defaults to half the window size.
    * `:sampling_rate` - the sampling rate $F_s$ in Hz. Defaults to `1000`.
    * `:scaling` - `nil`, `:spectrum` or `:psd`.
      * `:spectrum` - each frame is multiplied by $\sum_{i} window[i]$.
      * `nil` - No scaling is applied.
      * `:psd` - each frame is multiplied by $\sqrt{F\_s\sum_{i} window[i]^2}$.

  ## Examples

  In general, `istft/3` takes in the same parameters and window as the `stft/3` that generated the spectrum.
  In the first example, we can notice that the reconstruction is mostly perfect, aside from the first sample.

  This is because the Hann window only ensures perfect reconstruction in overlapping regions, so the edges
  of the signal end up being distorted.

      iex> t = Nx.tensor([10, 10, 1, 0, 10, 10, 2, 20])
      iex> w = NxSignal.Windows.hann(n: 4)
      iex> opts = [sampling_rate: 1, fft_length: 4]
      iex> {z, _time, _freqs} = NxSignal.stft(t, w, opts)
      iex> result = NxSignal.istft(z, w, opts)
      iex> Nx.as_type(result, Nx.type(t))
      #Nx.Tensor<
        s64[8]
        [0, 10, 1, 0, 10, 10, 2, 20]
      >

  Different scaling options are available (see `stft/3` for a more detailed explanation).
  For perfect reconstruction, you want to use the same scaling as the STFT:

      iex> t = Nx.tensor([10, 10, 1, 0, 10, 10, 2, 20])
      iex> w = NxSignal.Windows.hann(n: 4)
      iex> opts = [scaling: :spectrum, sampling_rate: 1, fft_length: 4]
      iex> {z, _time, _freqs} = NxSignal.stft(t, w, opts)
      iex> result = NxSignal.istft(z, w, opts)
      iex> Nx.as_type(result, Nx.type(t))
      #Nx.Tensor<
        s64[8]
        [0, 10, 1, 0, 10, 10, 2, 20]
      >

      iex> t = Nx.tensor([10, 10, 1, 0, 10, 10, 2, 20], type: :f32)
      iex> w = NxSignal.Windows.hann(n: 4)
      iex> opts = [scaling: :psd, sampling_rate: 1, fft_length: 4]
      iex> {z, _time, _freqs} = NxSignal.stft(t, w, opts)
      iex> result = NxSignal.istft(z, w, opts)
      iex> Nx.as_type(result, Nx.type(t))
      #Nx.Tensor<
        f32[8]
        [0.0, 10.0, 0.9999999403953552, -2.1900146407460852e-7, 10.0, 10.0, 2.000000238418579, 20.0]
      >
  """
  @doc type: :time_frequency
  defn istft(data, window, opts) do
    opts = keyword!(opts, [:fft_length, :overlap_length, :scaling, sampling_rate: 1000])

    fft_length =
      case opts[:fft_length] do
        nil ->
          :power_of_two

        fft_length ->
          fft_length
      end

    overlap_length =
      case opts[:overlap_length] do
        nil ->
          div(Nx.size(window), 2)

        overlap_length ->
          overlap_length
      end

    sampling_rate =
      case {opts[:scaling], opts[:sampling_rate]} do
        {:psd, nil} -> raise ArgumentError, ":sampling_rate is mandatory if scaling is :psd"
        {_, sampling_rate} -> sampling_rate
      end

    frames = Nx.ifft(data, length: fft_length)

    frames_rescaled =
      case opts[:scaling] do
        :spectrum ->
          frames * Nx.sum(window)

        :psd ->
          frames * Nx.sqrt(sampling_rate * Nx.sum(window ** 2))

        nil ->
          frames

        scaling ->
          raise ArgumentError,
                "invalid :scaling, expected one of :spectrum, :psd or nil, got: #{inspect(scaling)}"
      end

    result_non_normalized =
      overlap_and_add(frames_rescaled * window, overlap_length: overlap_length)

    normalization_factor =
      overlap_and_add(Nx.broadcast(Nx.abs(window) ** 2, data.shape),
        overlap_length: overlap_length
      )

    normalization_factor = Nx.select(normalization_factor > 1.0e-10, normalization_factor, 1.0)

    result_non_normalized / normalization_factor
  end

  @doc """
  Performs the overlap-and-add algorithm over
  an M by N tensor, where M is the number of
  windows and N is the window size.
  The tensor is zero-padded on the right so
  the last window fully appears in the result.

  ## Options

    * `:overlap_length` - The number of overlapping samples between windows
    * `:type` - output type for casting the accumulated result.
      If not given, defaults to `Nx.Type.to_complex/1` called on the input type.

  ## Examples
      iex> NxSignal.overlap_and_add(Nx.iota({3, 4}), overlap_length: 0)
      #Nx.Tensor<
        s64[12]
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
      >
      iex> NxSignal.overlap_and_add(Nx.iota({3, 4}), overlap_length: 3)
      #Nx.Tensor<
        s64[6]
        [0, 5, 15, 18, 17, 11]
      >
  """
  @doc type: :windowing
  defn overlap_and_add(tensor, opts \\ []) do
    opts = keyword!(opts, [:overlap_length])

    {num_windows, window_length} = Nx.shape(tensor)
    overlap_length = opts[:overlap_length]

    if overlap_length >= window_length do
      raise ArgumentError,
            "overlap_length must be a number less than the window size #{window_length}, got: #{inspect(window_length)}"
    end

    stride = window_length - overlap_length
    output_holder_shape = {num_windows * stride + overlap_length}

    {output, _, _, _, _, _} =
      while {
              out =
                Nx.broadcast(
                  Nx.tensor(0, type: tensor.type),
                  output_holder_shape
                ),
              tensor,
              i = 0,
              idx_template = Nx.iota({window_length, 1}),
              stride,
              num_windows
            },
            i < num_windows do
        current_window = tensor[i]
        idx = idx_template + i * stride

        {
          Nx.indexed_add(out, idx, current_window),
          tensor,
          i + 1,
          idx_template,
          stride,
          num_windows
        }
      end

    case opts[:type] do
      nil ->
        output

      t ->
        Nx.as_type(output, t)
    end
  end
end
