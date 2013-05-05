require 'active_support/inflector'
require 'forwardable'
module Dynflow
  class Bus

    class << self
      extend Forwardable

      def_delegators :impl, :trigger, :resume, :skip, :preview_execution_plan

      def impl
        @impl ||= Bus::MemoryBus.new
      end
      attr_writer :impl
    end

    # Entry point for running an action
    def trigger(action_class, *args)
      execution_plan = in_transaction_if_possible do
        prepare_execution_plan(action_class, *args)
      end
      persist_plan_if_possible(action_class, execution_plan)
      return execute(execution_plan)
    end

    def prepare_execution_plan(action_class, *args)
      action_class.plan(*args)
    end

    # execution and finalizaition. Usable for resuming paused plan
    # as well as starting from scratch
    def execute(execution_plan)
      run_execution_plan(execution_plan)
      in_transaction_if_possible do
        unless self.finalize(execution_plan)
          rollback_transaction
        end
      end
      execution_plan.persist
      return execution_plan
    end

    alias_method :resume, :execute

    def skip(step)
      step.status = 'skipped'
    end

    # return true if everyting worked fine
    def finalize(execution_plan)
      success = true
      if execution_plan.run_steps.any? { |action| ['pending', 'error'].include?(action.status) }
        success = false
      else
        execution_plan.finalize_steps.each(&:replace_references!)
        execution_plan.finalize_steps.each do |step|
          break unless success
          next if %w[skipped].include?(step.status)

          success = step.catch_errors do
            step.action.finalize(execution_plan.run_steps)
          end
        end
      end

      if success
        execution_plan.status = 'finished'
      else
        execution_plan.status = 'paused'
      end
      return success
    end

    # return true if the run phase finished successfully
    def run_execution_plan(execution_plan)
      success = true
      execution_plan.run_steps.map do |step|
        next step if !success || %w[skipped success].include?(step.status)
        step.persist_before_run
        success = step.catch_errors do
          step.output = {}
          step.action.run
        end
        step.persist_after_run
        step
      end
      return success
    end

    def transaction_driver
      nil
    end

    def in_transaction_if_possible
      if transaction_driver
        ret = nil
        transaction_driver.transaction do
          ret = yield
        end
        return ret
      else
        return yield
      end
    end

    def rollback_transaction
      transaction_driver.rollback if transaction_driver
    end


    def persistence_driver
      nil
    end

    def persist_plan_if_possible(action_class, execution_plan)
      if persistence_driver
        persistence_driver.persist(action_class, execution_plan)
      end
    end

    # performs the planning phase of an action, but rollbacks any db
    # changes done in this phase. Returns the resulting execution
    # plan. Suitable for debugging.
    def preview_execution_plan(action_class, *args)
      unless transaction_driver
        raise "Bus doesn't know how to run in transaction"
      end

      execution_plan = nil
      transaction_driver.transaction do
        execution_plan = prepare_execution_plan(action_class, *args)
        transaction_driver.rollback
      end
      return execution_plan
    end

    def logger
      @logger ||= Dynflow::Logger.new(self.class)
    end

    class MemoryBus < Bus
      # No modifications needed: the default implementation is
      # in memory. TODO: get rid of this class
    end

    class ActiveRecordTransaction
      class << self

        def transaction(&block)
          ActiveRecord::Base.transaction(&block)
        end

        def rollback
          raise ActiveRecord::Rollback
        end

      end
    end

    # uses Rails API for db features
    # encapsulates the planning and finalization phase into
    class RailsBus < Bus

      def transaction_driver
        ActiveRecordTransaction
      end

      def persistence_driver
        Dynflow::Journal
      end

    end

  end
end