# frozen_string_literal: true

require 'yaml'

# ==== DB? ====

class Database
  class CrudeDB
    def initialize(dbf)
      @dbf = dbf
      @db = File.exist?(@dbf) ? YAML.load(File.read(@dbf)) : {}
    end
    def [](key)
      @db[key]
    end
    def []=(key,val)
      @db[key] = val
    end
    def save
      File.write(@dbf, @db.to_yaml)
    end
  end

  class ModifiedArray < Array
    def initialize(*args)
      super *args
      @listener = nil
    end

    def listen?
      not @listener.nil?
    end

    def listen
      @listener = proc do
        yield
      end
    end

    def encode_with(coder)
      coder.seq = self
    end

    def init_with(coder) # seems not working?
      if coder.type == :seq
        replace coder.seq
      else
        raise "Read from YAML: data invalid"
      end
      self
    end

    def self.notify_save(*methods)
      methods.each do |method|
        define_method(method) do |*args, &block|
          ret = super *args, &block
          @listener.call if @listener
          ret
        end
      end
    end

    notify_save :[]=, :append, :clear, :collect!, :compact!, :delete, :delete_at, :delete_if, :fill, :filter!, :faltten!, :insert, :keep_if, :map!, :pop, :prepend, :push, :reject!, :replace, :reverse!, :rotate!, :select!, :shift, :shuffle!, :slice!, :sort!, :sort_by!, :uniq!, :unshift
  end

  def initialize(conf)
    @conf = conf
    @backend = CrudeDB.new @conf[:filename]
  end

  def self.define_attr(*attrs)
    attrs.each do |attr|
      define_method(attr) do
        @backend[attr]
      end
      define_method("#{attr}=") do |val|
        @backend[attr] = val
        @backend.save
      end
    end
  end

  def self.define_array(*attrs)
    attrs.each do |attr|
      define_method(attr) do
        arr = @backend[attr]
        @backend[attr] = arr = ModifiedArray.new arr if arr.is_a? Array
        @backend[attr] = arr = ModifiedArray.new unless arr
        arr.listen { @backend.save } unless arr.listen?
        arr
      end
      define_method("#{attr}=") do |val|
        arr = send attr
        arr.replace val
      end
    end
  end

  define_attr :twitch_token, :twitch_eventsub_secret
  #define_array :twitch_eventsub_subscriptions
end

