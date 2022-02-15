# frozen_string_literal: true

module ActiveSupport
  module Cache
    class RedisHashStore < RedisCacheStore
      MISSING_BLOCK_MSG = "Missing block: Calling `Cache#fetch` with `force: true` requires a block."

      def initialize(options)
        super(**options)
      end

      def write_hash_value(prefix, key, value, options = nil)
        options = merged_options(options)
        prefix = normalize_key(prefix, options)

        instrument(:write_hash_value, [prefix, key], options) do
          entry = Entry.new(value, **options.merge(version: normalize_version(prefix, options)))
          write_hash_entry(prefix, key, entry, **options)
        end
      end

      def read_hash_value(prefix, key, options = nil)
        options = merged_options(options)
        prefix = normalize_key(prefix, options)
        version = normalize_version(prefix, options)

        instrument(:read_hash_value, [prefix, key]) do |payload|
          entry = read_hash_entry(prefix, key, **options)

          if entry
            if entry.expired?
              delete_hash_entry(key)
              payload[:hit] = false if payload
              nil
            elsif entry.mismatched?(version)
              payload[:hit] = false if payload
              nil
            else
              payload[:hit] = true if payload
              entry.value
            end
          else
            payload[:hit] = false if payload
            nil
          end
        end
      end

      def fetch_hash_value(prefix, key, **options, &block)
        if block_given?
          options = merged_options(options)
          prefix = normalize_key(prefix, options)

          entry = nil
          instrument(:read_hash, [prefix, key], options) do |payload|
            cached_entry = read_hash_entry(prefix, key, **options, event: payload) unless options[:force]
            entry = handle_expired_hash_entry(cached_entry, prefix, key, options)
            entry = nil if entry&.mismatched?(normalize_version(key, options))
            payload[:super_operation] = :fetch_hash_value if payload
            payload[:hit] = !!entry if payload
          end

          if entry
            get_entry_value(entry, prefix, options)
          else
            save_hash_block_result_to_cache(prefix, key, options, &block)
          end
        elsif options && options[:force]
          raise(ArgumentError, MISSING_BLOCK_MSG)
        else
          read_hash_value(prefix, key, options)
        end
      end

      def delete_hash_value(prefix, key, options = nil)
        options = merged_options(options)
        prefix = normalize_key(prefix, options)

        instrument(:delete_hash_value, [prefix, key]) do
          delete_hash_entry(prefix, key)
        end
      end

      def read_hash(prefix, options = nil)
        options = merged_options(options)
        prefix = normalize_key(prefix, options)

        instrument(:read_hash, prefix) do
          read_hash_entries(prefix).map do |key, entry|
            if entry.expired?
              delete_hash_entry(prefix, key)
              nil
            else
              [key, entry.value]
            end
          end.compact.to_h
        end
      end

      def delete_hash(prefix, options = nil)
        options = merged_options(options)
        prefix = normalize_key(prefix, options)

        instrument(:delete_hash, prefix) do
          delete_hash_entries(prefix)
        end
      end

      private

      def delete_hash_entry(prefix, key)
        failsafe(:delete_hash_entry, returning: false) do
          redis.with { |c| c.hdel(prefix, key) }
        end
      end

      def read_hash_entry(prefix, key, **options)
        failsafe(:read_hash_entry) do
          deserialize_entry(redis.with { |c| c.hget(prefix, key) }, **options)
        end
      end

      def write_hash_entry(prefix, key, entry, raw: false, **options)
        serialized_entry = serialize_entry(entry, raw: raw, **options)

        failsafe(:write_hash_entry, returning: false) do
          redis.with do |connection|
            connection.hset(prefix, key, serialized_entry)
          end
        end
      end

      def read_hash_entries(prefix, **options)
        failsafe(:read_hash_entries, returning: false) do
          redis.with do |connection|
            connection.hgetall(prefix).transform_values do |value|
              deserialize_entry(value, **options)
            end
          end
        end
      end

      def delete_hash_entries(prefix)
        redis.with { |c| c.del(prefix) }
      end

      def handle_expired_hash_entry(entry, prefix, key, options)
        if entry&.expired?
          race_ttl = options[:race_condition_ttl].to_i
          if (race_ttl > 0) && (Time.now.to_f - entry.expires_at <= race_ttl)
            # When an entry has a positive :race_condition_ttl defined, put the stale entry back into the cache
            # for a brief period while the entry is being recalculated.
            entry.expires_at = Time.now + race_ttl
            write_hash_entry(prefix, key, entry)
          else
            delete_hash_entry(prefix, key)
          end
          entry = nil
        end
        entry
      end

      def deserialize_entry(payload, raw: false, **)
        if raw && !payload.nil?
          Entry.new(payload)
        else
          super(payload, raw: raw)
        end
      end

      def serialize_entry(entry, raw: false, **_options)
        if raw
          entry.value.to_s
        else
          super(entry, raw: raw)
        end
      end

      def save_hash_block_result_to_cache(prefix, key, options)
        result = instrument(:generate, [prefix, key], options) do
          yield([prefix, key])
        end

        write_hash_value(prefix, key, result, options) unless result.nil? && options[:skip_nil]
        result
      end
    end
  end
end
