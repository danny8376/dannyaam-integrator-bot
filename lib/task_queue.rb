# frozen_string_literal: true

class TaskQueue
  def initialize
    @queue = {}
  end

  def register(name)
    @queue[name] = Queue.new
  end

  def consume(name)
    register name unless @queue[name]
    @queue[name].pop
  end

  def push(name, cont)
    if @queue[name]
      @queue[name].push cont
    end
  end
end
