# frozen_string_literal: true

require "spec_helper"
require "igniter/ai"

RSpec.describe Igniter::AI::Transcriber do
  # ── Shared mock provider ───────────────────────────────────────────────────

  def mock_transcription_provider(result)
    Class.new(Igniter::AI::Transcription::Providers::Base) do
      define_method(:transcribe) { |*_args, **_kw| result }
    end.new
  end

  let(:sample_result) do
    Igniter::AI::Transcription::TranscriptResult.new(
      text: "Добрый день, чем могу помочь?",
      words: [],
      speakers: nil,
      language: "ru",
      duration: 4.5,
      provider: :deepgram,
      model: "nova-3",
      raw: {}
    )
  end

  # ── DSL ────────────────────────────────────────────────────────────────────

  describe "class DSL" do
    describe ".transcription_provider" do
      it "stores the provider name as symbol" do
        klass = Class.new(described_class) { transcription_provider :deepgram }
        expect(klass.transcription_provider).to eq(:deepgram)
      end

      it "rejects unknown providers" do
        expect do
          Class.new(described_class) { transcription_provider :unknown }
        end.to raise_error(ArgumentError, /unknown/i)
      end
    end

    describe ".model" do
      it "stores the model string" do
        klass = Class.new(described_class) { model "nova-3" }
        expect(klass.model).to eq("nova-3")
      end
    end

    describe ".language" do
      it "stores the language code" do
        klass = Class.new(described_class) { language "ru" }
        expect(klass.language).to eq("ru")
      end
    end

    describe ".diarize / .diarize?" do
      it "defaults to false" do
        klass = Class.new(described_class)
        expect(klass.diarize?).to be false
      end

      it "can be enabled" do
        klass = Class.new(described_class) { diarize true }
        expect(klass.diarize?).to be true
      end
    end

    describe ".word_timestamps" do
      it "defaults to true" do
        klass = Class.new(described_class)
        expect(klass.word_timestamps).to be true
      end

      it "can be disabled" do
        klass = Class.new(described_class) { word_timestamps false }
        expect(klass.word_timestamps).to be false
      end
    end

    describe ".poll_interval / .poll_timeout" do
      it "defaults to 2 and 300" do
        klass = Class.new(described_class)
        expect(klass.poll_interval).to eq(2)
        expect(klass.poll_timeout).to eq(300)
      end

      it "stores custom values" do
        klass = Class.new(described_class) do
          poll_interval 5
          poll_timeout  120
        end
        expect(klass.poll_interval).to eq(5.0)
        expect(klass.poll_timeout).to eq(120.0)
      end
    end
  end

  # ── Inheritance ────────────────────────────────────────────────────────────

  describe "DSL inheritance" do
    it "copies all DSL settings to subclass" do
      parent = Class.new(described_class) do
        transcription_provider :deepgram
        model "nova-3"
        language "ru"
        diarize true
        poll_interval 5
        poll_timeout 120
      end
      child = Class.new(parent)

      expect(child.transcription_provider).to eq(:deepgram)
      expect(child.model).to eq("nova-3")
      expect(child.language).to eq("ru")
      expect(child.diarize?).to be true
      expect(child.poll_interval).to eq(5.0)
      expect(child.poll_timeout).to eq(120.0)
    end

    it "child override does not mutate parent" do
      parent = Class.new(described_class) do
        transcription_provider :openai
        model "whisper-1"
      end
      child = Class.new(parent) do
        transcription_provider :deepgram
        model "nova-3"
      end

      expect(parent.transcription_provider).to eq(:openai)
      expect(child.transcription_provider).to eq(:deepgram)
    end
  end

  # ── #transcribe delegate ───────────────────────────────────────────────────

  describe "#transcribe" do
    it "delegates to the provider and returns TranscriptResult" do
      provider = mock_transcription_provider(sample_result)

      klass = Class.new(described_class) do
        transcription_provider :deepgram
        model "nova-3"
        define_method(:call) { |audio_path:| transcribe(audio_path) }
      end

      instance = klass.new
      instance.define_singleton_method(:provider_instance) { provider }

      result = instance.call(audio_path: "call.mp3")
      expect(result).to be_a(Igniter::AI::Transcription::TranscriptResult)
      expect(result.text).to eq("Добрый день, чем могу помочь?")
      expect(result.language).to eq("ru")
      expect(result.duration).to eq(4.5)
    end

    it "raises ConfigurationError when transcription_provider is not set" do
      klass = Class.new(described_class) do
        define_method(:call) { |audio_path:| transcribe(audio_path) }
      end
      expect { klass.call(audio_path: "x.mp3") }
        .to raise_error(Igniter::AI::ConfigurationError, /transcription_provider not configured/)
    end
  end

  # ── Default models ─────────────────────────────────────────────────────────

  describe "default models" do
    {
      openai: "whisper-1",
      deepgram: "nova-3",
      assemblyai: "universal-2"
    }.each do |prov, expected_model|
      it "uses #{expected_model} as default model for :#{prov}" do
        received_model = nil
        # Capture let-defined result in a local variable so the define_method
        # proc can reference it regardless of what `self` is at call-time.
        fixture = Igniter::AI::Transcription::TranscriptResult.new(
          text: "ok", words: [], speakers: nil, language: nil,
          duration: 1.0, provider: prov, model: expected_model, raw: {}
        )
        provider_spy = Class.new(Igniter::AI::Transcription::Providers::Base) do
          define_method(:transcribe) do |_src, model:, **_kw|
            received_model = model
            fixture
          end
        end.new

        klass = Class.new(described_class) do
          transcription_provider prov
          define_method(:call) { |audio_path:| transcribe(audio_path) }
        end

        allow_any_instance_of(klass).to receive(:provider_instance).and_return(provider_spy)

        result = klass.call(audio_path: "audio.wav")
        expect(result).to be_a(Igniter::AI::Transcription::TranscriptResult)
        expect(received_model).to eq(expected_model)
      end
    end
  end

  # ── Executor interface ─────────────────────────────────────────────────────

  describe "Executor interface" do
    it "responds to .call (Executor class method)" do
      expect(described_class).to respond_to(:call)
    end

    it "is a subclass of Igniter::Executor" do
      expect(described_class).to be < Igniter::Executor
    end
  end
end

# ── TranscriptResult ──────────────────────────────────────────────────────────

RSpec.describe Igniter::AI::Transcription::TranscriptResult do
  subject do
    described_class.new(
      text: "Hello world", words: [], speakers: nil,
      language: "en", duration: 2.5, provider: :openai, model: "whisper-1", raw: {}
    )
  end

  it "has the expected attributes" do
    expect(subject.text).to eq("Hello world")
    expect(subject.language).to eq("en")
    expect(subject.duration).to eq(2.5)
    expect(subject.provider).to eq(:openai)
    expect(subject.model).to eq("whisper-1")
  end

  it "speakers can be nil (no diarization)" do
    expect(subject.speakers).to be_nil
  end
end

RSpec.describe Igniter::AI::Transcription::TranscriptWord do
  subject do
    described_class.new(word: "hello", start_time: 0.1, end_time: 0.4, confidence: 0.99, speaker: 0)
  end

  it "exposes word-level attributes" do
    expect(subject.word).to eq("hello")
    expect(subject.start_time).to eq(0.1)
    expect(subject.end_time).to eq(0.4)
    expect(subject.confidence).to eq(0.99)
    expect(subject.speaker).to eq(0)
  end

  it "speaker is nil when diarization not used" do
    word = described_class.new(word: "hi", start_time: 0.0, end_time: 0.2, confidence: nil, speaker: nil)
    expect(word.speaker).to be_nil
  end
end

RSpec.describe Igniter::AI::Transcription::SpeakerSegment do
  subject do
    described_class.new(speaker: 0, start_time: 0.0, end_time: 5.5, text: "Добрый день")
  end

  it "exposes segment attributes" do
    expect(subject.speaker).to eq(0)
    expect(subject.start_time).to eq(0.0)
    expect(subject.end_time).to eq(5.5)
    expect(subject.text).to eq("Добрый день")
  end
end

# ── Provider: OpenAI ──────────────────────────────────────────────────────────

RSpec.describe Igniter::AI::Transcription::Providers::OpenAI do
  subject(:provider) { described_class.new(api_key: "test-key") }

  describe "#transcribe" do
    let(:raw_response) do
      {
        "text" => "Hello world",
        "language" => "en",
        "duration" => 3.0,
        "words" => [
          { "word" => "Hello", "start" => 0.0, "end" => 0.4, "confidence" => 0.99 },
          { "word" => "world", "start" => 0.5, "end" => 0.9, "confidence" => 0.98 }
        ]
      }
    end

    before do
      allow(provider).to receive(:post_multipart).and_return(raw_response)
      allow(provider).to receive(:read_audio).and_return("fake audio binary".b)
    end

    it "returns a TranscriptResult" do
      result = provider.transcribe("call.mp3", model: "whisper-1")
      expect(result).to be_a(Igniter::AI::Transcription::TranscriptResult)
      expect(result.text).to eq("Hello world")
      expect(result.language).to eq("en")
      expect(result.duration).to eq(3.0)
      expect(result.provider).to eq(:openai)
      expect(result.model).to eq("whisper-1")
    end

    it "maps word-level timestamps" do
      result = provider.transcribe("call.mp3", model: "whisper-1")
      expect(result.words.length).to eq(2)
      expect(result.words.first.word).to eq("Hello")
      expect(result.words.first.start_time).to eq(0.0)
      expect(result.words.first.end_time).to eq(0.4)
      expect(result.words.first.confidence).to eq(0.99)
    end

    it "sets speaker to nil (Whisper has no diarization)" do
      result = provider.transcribe("call.mp3", model: "whisper-1")
      expect(result.words.map(&:speaker)).to all(be_nil)
      expect(result.speakers).to be_nil
    end

    it "raises ConfigurationError when api_key is absent" do
      p = described_class.new(api_key: nil)
      expect { p.transcribe("x.mp3", model: "whisper-1") }
        .to raise_error(Igniter::AI::ConfigurationError, /OPENAI_API_KEY/)
    end
  end
end

# ── Provider: Deepgram ────────────────────────────────────────────────────────

RSpec.describe Igniter::AI::Transcription::Providers::Deepgram do
  subject(:provider) { described_class.new(api_key: "dg-key") }

  let(:dg_response) do
    {
      "results" => {
        "channels" => [{
          "detected_language" => "ru",
          "alternatives" => [{
            "transcript" => "Добрый день",
            "confidence" => 0.97,
            "words" => [
              { "word" => "Добрый", "punctuated_word" => "Добрый", "start" => 0.0, "end" => 0.4, "confidence" => 0.99,
                "speaker" => 0 },
              { "word" => "день",   "punctuated_word" => "день",   "start" => 0.5, "end" => 0.9, "confidence" => 0.96,
                "speaker" => 0 }
            ]
          }]
        }],
        "utterances" => [
          { "speaker" => 0, "start" => 0.0, "end" => 0.9, "transcript" => "Добрый день" }
        ]
      },
      "metadata" => { "duration" => 0.9, "detected_language" => "ru" }
    }
  end

  before do
    allow(provider).to receive(:post_binary).and_return(dg_response)
    allow(provider).to receive(:read_audio).and_return("fake audio".b)
  end

  it "returns a TranscriptResult" do
    result = provider.transcribe("call.wav", model: "nova-3")
    expect(result.text).to eq("Добрый день")
    expect(result.language).to eq("ru")
    expect(result.provider).to eq(:deepgram)
    expect(result.duration).to eq(0.9)
  end

  it "maps word-level timestamps with speaker" do
    result = provider.transcribe("call.wav", model: "nova-3", diarize: true)
    expect(result.words.length).to eq(2)
    expect(result.words.first.speaker).to eq(0)
  end

  it "builds speaker segments from utterances when diarize: true" do
    result = provider.transcribe("call.wav", model: "nova-3", diarize: true)
    expect(result.speakers).not_to be_nil
    expect(result.speakers.length).to eq(1)
    seg = result.speakers.first
    expect(seg.speaker).to eq(0)
    expect(seg.text).to eq("Добрый день")
  end

  it "sets speakers to nil when diarize: false" do
    result = provider.transcribe("call.wav", model: "nova-3", diarize: false)
    expect(result.speakers).to be_nil
  end

  it "raises ConfigurationError when api_key is absent" do
    p = described_class.new(api_key: nil)
    expect { p.transcribe("x.wav", model: "nova-3") }
      .to raise_error(Igniter::AI::ConfigurationError, /DEEPGRAM_API_KEY/)
  end
end

# ── Provider: AssemblyAI ──────────────────────────────────────────────────────

RSpec.describe Igniter::AI::Transcription::Providers::AssemblyAI do
  subject(:provider) { described_class.new(api_key: "aai-key", poll_interval: 0.01, poll_timeout: 5) }

  let(:completed_response) do
    {
      "id" => "abc123",
      "status" => "completed",
      "text" => "Hello there",
      "language_code" => "en",
      "audio_duration" => 2.1,
      "words" => [
        { "text" => "Hello", "start" => 0,    "end" => 400,  "confidence" => 0.99, "speaker" => "A" },
        { "text" => "there", "start" => 500,  "end" => 900,  "confidence" => 0.97, "speaker" => "A" }
      ],
      "utterances" => [
        { "speaker" => "A", "start" => 0, "end" => 900, "text" => "Hello there" }
      ]
    }
  end

  before do
    allow(provider).to receive(:read_audio).and_return("audio".b)
    allow(provider).to receive(:upload_file).and_return("https://cdn.assemblyai.com/x")
    allow(provider).to receive(:submit_job).and_return("abc123")
    allow(provider).to receive(:fetch_transcript).and_return(completed_response)
  end

  it "returns a TranscriptResult after polling" do
    result = provider.transcribe("call.mp3", model: "universal-2")
    expect(result.text).to eq("Hello there")
    expect(result.language).to eq("en")
    expect(result.duration).to eq(2.1)
    expect(result.provider).to eq(:assemblyai)
  end

  it "converts millisecond timestamps to seconds" do
    result = provider.transcribe("call.mp3", model: "universal-2")
    expect(result.words.first.start_time).to eq(0.0)
    expect(result.words.first.end_time).to eq(0.4)
    expect(result.words.last.start_time).to eq(0.5)
  end

  it "uses letter-based speaker labels from AssemblyAI" do
    result = provider.transcribe("call.mp3", model: "universal-2", diarize: true)
    expect(result.speakers).not_to be_nil
    expect(result.speakers.first.speaker).to eq("A")
    expect(result.speakers.first.text).to eq("Hello there")
  end

  it "raises ProviderError when job status is error" do
    allow(provider).to receive(:fetch_transcript).and_return({
                                                               "status" => "error", "error" => "unsupported format"
                                                             })
    expect { provider.transcribe("x.mp3", model: "universal-2") }
      .to raise_error(Igniter::AI::ProviderError, /unsupported format/)
  end

  it "raises ProviderError on poll timeout" do
    allow(provider).to receive(:fetch_transcript).and_return({ "status" => "processing" })
    p = described_class.new(api_key: "aai-key", poll_interval: 0.01, poll_timeout: 0.02)
    allow(p).to receive(:read_audio).and_return("x".b)
    allow(p).to receive(:upload_file).and_return("https://cdn.assemblyai.com/x")
    allow(p).to receive(:submit_job).and_return("j1")
    allow(p).to receive(:fetch_transcript).and_return({ "status" => "processing" })
    expect { p.transcribe("x.mp3", model: "universal-2") }
      .to raise_error(Igniter::AI::ProviderError, /timed out/)
  end

  it "raises ConfigurationError when api_key is absent" do
    p = described_class.new(api_key: nil)
    expect { p.transcribe("x.mp3", model: "universal-2") }
      .to raise_error(Igniter::AI::ConfigurationError, /ASSEMBLYAI_API_KEY/)
  end
end

# ── LLM Config: transcription providers ──────────────────────────────────────

RSpec.describe Igniter::AI::Config do
  subject(:cfg) { described_class.new }

  describe "transcription providers" do
    it "exposes deepgram config" do
      expect(cfg.deepgram).to be_a(Igniter::AI::Config::DeepgramConfig)
      expect(cfg.deepgram.base_url).to eq("https://api.deepgram.com")
    end

    it "exposes assemblyai config" do
      expect(cfg.assemblyai).to be_a(Igniter::AI::Config::AssemblyAIConfig)
      expect(cfg.assemblyai.poll_timeout).to eq(300)
    end

    it "shares openai config between chat and transcription" do
      expect(cfg.transcription_providers[:openai]).to be(cfg.openai)
    end

    it "transcription_provider_config raises on unknown" do
      expect { cfg.transcription_provider_config(:unknown) }
        .to raise_error(ArgumentError, /unknown/i)
    end
  end
end

# ── Multipart builder ─────────────────────────────────────────────────────────

RSpec.describe Igniter::AI::Transcription::Providers::Base do
  subject(:base) { described_class.new }

  describe "#build_multipart (via send)" do
    it "produces a body containing the boundary and field content" do
      body, boundary = base.send(:build_multipart, {
                                   "model" => "whisper-1",
                                   "file" => { data: "AUDIO".b, filename: "a.mp3", content_type: "audio/mpeg" }
                                 })
      expect(body).to include(boundary)
      expect(body.b).to include("whisper-1")
      expect(body.b).to include("a.mp3")
    end

    it "returns body as binary String" do
      body, _boundary = base.send(:build_multipart, { "key" => "val" })
      expect(body.encoding.to_s).to eq("ASCII-8BIT")
    end
  end

  describe "#audio_content_type" do
    {
      "audio.mp3" => "audio/mpeg",
      "audio.wav" => "audio/wav",
      "audio.m4a" => "audio/mp4",
      "audio.webm" => "audio/webm",
      "audio.flac" => "audio/flac",
      "audio.xyz" => "application/octet-stream"
    }.each do |filename, expected|
      it "returns #{expected} for #{filename}" do
        expect(base.send(:audio_content_type, filename)).to eq(expected)
      end
    end
  end
end
