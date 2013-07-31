require_relative 'test_helper'
require_relative 'code_workflow_example'

module Dynflow
  module ExecutorTest
    describe "executor" do

      include PlanAssertions

      let :world do
        SimpleWorld.new
      end

      let :issues_data do
        [{ 'author' => 'Peter Smith', 'text' => 'Failing test' },
         { 'author' => 'John Doe', 'text' => 'Internal server error' }]
      end

      let :execution_plan do
        world.plan(CodeWorkflowExample::IncommingIssues, issues_data)
      end

      describe "execution of run flow" do

        before do
          TestExecutionLog.setup
          result = world.execute(execution_plan.id).value
          raise result if result.is_a? Exception
        end

        after do
          TestExecutionLog.teardown
        end

        let :persisted_plan do
          world.persistence.load_execution_plan(execution_plan.id)
        end

        it "runs all the steps in the run flow" do
          assert_run_flow <<-EXECUTED_RUN_FLOW, persisted_plan
            Dynflow::Flows::Concurrence
              Dynflow::Flows::Sequence
                4: Triage(success) {"author"=>"Peter Smith", "text"=>"Failing test"} --> {"classification"=>{"assignee"=>"John Doe", "severity"=>"medium"}}
                7: UpdateIssue(success) {"author"=>"Peter Smith", "text"=>"Failing test", "assignee"=>"John Doe", "severity"=>"medium"} --> {}
                9: NotifyAssignee(success) {"triage"=>{"classification"=>{"assignee"=>"John Doe", "severity"=>"medium"}}} --> {}
              Dynflow::Flows::Sequence
                13: Triage(success) {"author"=>"John Doe", "text"=>"Internal server error"} --> {"classification"=>{"assignee"=>"John Doe", "severity"=>"medium"}}
                16: UpdateIssue(success) {"author"=>"John Doe", "text"=>"Internal server error", "assignee"=>"John Doe", "severity"=>"medium"} --> {}
                18: NotifyAssignee(success) {"triage"=>{"classification"=>{"assignee"=>"John Doe", "severity"=>"medium"}}} --> {}
          EXECUTED_RUN_FLOW
        end

        it "runs all the steps in the finalize flow" do
          assert_finalized(Dynflow::CodeWorkflowExample::IncommingIssues,
                           {"issues"=>[{"author"=>"Peter Smith", "text"=>"Failing test"}, {"author"=>"John Doe", "text"=>"Internal server error"}]})
          assert_finalized(Dynflow::CodeWorkflowExample::Triage,
                           {"author"=>"Peter Smith", "text"=>"Failing test"})
        end

      end
    end
  end
end



