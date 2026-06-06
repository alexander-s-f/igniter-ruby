# frozen_string_literal: true

require "zlib"

module Igniter
  module Store
    # Shared CRC32-framed binary encoding for WAL files and network transport.
    #
    # Frame layout:
    #   [4 bytes BE uint32: body_len][body_len bytes: body][4 bytes BE uint32: CRC32(body)]
    #
    # A frame with a mismatched CRC or truncated body signals corruption /
    # connection loss — the caller should stop reading.
    module WireProtocol
      FRAME_HEADER_SIZE = 4
      FRAME_CRC_SIZE    = 4

      def encode_frame(body)
        body_b = body.b
        [body_b.bytesize].pack("N") << body_b << [Zlib.crc32(body)].pack("N")
      end

      # Reads one frame from +io+. Returns the body String on success, nil on
      # truncation or CRC mismatch.
      def read_frame(io)
        header = io.read(FRAME_HEADER_SIZE)
        return nil if header.nil? || header.bytesize < FRAME_HEADER_SIZE

        len  = header.unpack1("N")
        body = io.read(len)
        return nil if body.nil? || body.bytesize < len

        crc_bytes = io.read(FRAME_CRC_SIZE)
        return nil if crc_bytes.nil? || crc_bytes.bytesize < FRAME_CRC_SIZE

        return nil unless Zlib.crc32(body) == crc_bytes.unpack1("N")

        body
      end
    end
  end
end
