# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Ci::UpdateBuildStateService do
  let(:project) { create(:project) }
  let(:pipeline) { create(:ci_pipeline, project: project) }
  let(:build) { create(:ci_build, :running, pipeline: pipeline) }
  let(:metrics) { spy('metrics') }

  subject { described_class.new(build, params) }

  before do
    stub_feature_flags(ci_enable_live_trace: true)
  end

  context 'when build does not have checksum' do
    context 'when state has changed' do
      let(:params) { { state: 'success' } }

      it 'updates a state of a running build' do
        subject.execute

        expect(build).to be_success
      end

      it 'returns 200 OK status' do
        result = subject.execute

        expect(result.status).to eq 200
      end

      it 'does not increment finalized trace metric' do
        execute_with_stubbed_metrics!

        expect(metrics)
          .not_to have_received(:increment_trace_operation)
          .with(operation: :finalized)
      end
    end

    context 'when it is a heartbeat request' do
      let(:params) { { state: 'success' } }

      it 'updates a build timestamp' do
        expect { subject.execute }.to change { build.updated_at }
      end
    end

    context 'when request payload carries a trace' do
      let(:params) { { state: 'success', trace: 'overwritten' } }

      it 'overwrites a trace' do
        result = subject.execute

        expect(build.trace.raw).to eq 'overwritten'
        expect(result.status).to eq 200
      end

      it 'updates overwrite operation metric' do
        execute_with_stubbed_metrics!

        expect(metrics)
          .to have_received(:increment_trace_operation)
          .with(operation: :overwrite)
      end
    end

    context 'when state is unknown' do
      let(:params) { { state: 'unknown' } }

      it 'responds with 400 bad request' do
        result = subject.execute

        expect(result.status).to eq 400
        expect(build).to be_running
      end
    end
  end

  context 'when build has a checksum' do
    let(:params) do
      { checksum: 'crc32:12345678', state: 'failed', failure_reason: 'script_failure' }
    end

    context 'when build trace has been migrated' do
      before do
        create(:ci_build_trace_chunk, :database_with_data, build: build)
      end

      it 'updates a build state' do
        subject.execute

        expect(build).to be_failed
      end

      it 'responds with 200 OK status' do
        result = subject.execute

        expect(result.status).to eq 200
      end

      it 'increments trace finalized operation metric' do
        execute_with_stubbed_metrics!

        expect(metrics)
          .to have_received(:increment_trace_operation)
          .with(operation: :finalized)
      end
    end

    context 'when build trace has not been migrated yet' do
      before do
        create(:ci_build_trace_chunk, :redis_with_data, build: build)
      end

      it 'does not update a build state' do
        subject.execute

        expect(build).to be_running
      end

      it 'responds with 202 accepted' do
        result = subject.execute

        expect(result.status).to eq 202
      end

      it 'schedules live chunks for migration' do
        expect(Ci::BuildTraceChunkFlushWorker)
          .to receive(:perform_async)
          .with(build.trace_chunks.first.id)

        subject.execute
      end

      it 'increments trace accepted operation metric' do
        execute_with_stubbed_metrics!

        expect(metrics)
          .to have_received(:increment_trace_operation)
          .with(operation: :accepted)
      end

      it 'creates a pending state record' do
        subject.execute

        build.pending_state.then do |status|
          expect(status).to be_present
          expect(status.state).to eq 'failed'
          expect(status.trace_checksum).to eq 'crc32:12345678'
          expect(status.failure_reason).to eq 'script_failure'
        end
      end

      context 'when build pending state is outdated' do
        before do
          build.create_pending_state(
            state: 'failed',
            trace_checksum: 'crc32:12345678',
            failure_reason: 'script_failure',
            created_at: 10.minutes.ago
          )
        end

        it 'responds with 200 OK' do
          result = subject.execute

          expect(result.status).to eq 200
        end

        it 'updates build state' do
          subject.execute

          expect(build.reload).to be_failed
          expect(build.failure_reason).to eq 'script_failure'
        end

        it 'increments discarded traces metric' do
          execute_with_stubbed_metrics!

          expect(metrics)
            .to have_received(:increment_trace_operation)
            .with(operation: :discarded)
        end

        it 'does not increment finalized trace metric' do
          execute_with_stubbed_metrics!

          expect(metrics)
            .not_to have_received(:increment_trace_operation)
            .with(operation: :finalized)
        end
      end

      context 'when build pending state has changes' do
        before do
          build.create_pending_state(
            state: 'success',
            created_at: 10.minutes.ago
          )
        end

        it 'uses stored state and responds with 200 OK' do
          result = subject.execute

          expect(result.status).to eq 200
        end

        it 'increments conflict trace metric' do
          execute_with_stubbed_metrics!

          expect(metrics)
            .to have_received(:increment_trace_operation)
            .with(operation: :conflict)
        end
      end

      context 'when live traces are disabled' do
        before do
          stub_feature_flags(ci_enable_live_trace: false)
        end

        it 'responds with 200 OK' do
          result = subject.execute

          expect(result.status).to eq 200
        end
      end
    end
  end

  def execute_with_stubbed_metrics!
    described_class
      .new(build, params, metrics)
      .execute
  end
end
