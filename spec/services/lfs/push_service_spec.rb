# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Lfs::PushService do
  let(:logger) { service.send(:logger) }
  let(:lfs_client) { service.send(:lfs_client) }

  let_it_be(:project) { create(:forked_project_with_submodules) }
  let_it_be(:remote_mirror) { create(:remote_mirror, project: project, enabled: true) }
  let_it_be(:lfs_object) { create_linked_lfs_object(project, :project) }

  let(:params) { { url: remote_mirror.bare_url, credentials: remote_mirror.credentials } }

  subject(:service) { described_class.new(project, nil, params) }

  describe "#execute" do
    it 'uploads the object when upload is requested' do
      stub_lfs_batch(lfs_object)

      expect(lfs_client)
        .to receive(:upload)
        .with(lfs_object, upload_action_spec(lfs_object), authenticated: true)

      expect(service.execute).to eq(status: :success)
    end

    it 'does nothing if there are no LFS objects' do
      lfs_object.destroy!

      expect(lfs_client).not_to receive(:upload)

      expect(service.execute).to eq(status: :success)
    end

    it 'does not upload the object when upload is not requested' do
      stub_lfs_batch(lfs_object, upload: false)

      expect(lfs_client).not_to receive(:upload)

      expect(service.execute).to eq(status: :success)
    end

    it 'returns a failure when submitting a batch fails' do
      expect(lfs_client).to receive(:batch) { raise 'failed' }

      expect(service.execute).to eq(status: :error, message: 'failed')
    end

    it 'returns a failure when submitting an upload fails' do
      stub_lfs_batch(lfs_object)
      expect(lfs_client).to receive(:upload) { raise 'failed' }

      expect(service.execute).to eq(status: :error, message: 'failed')
    end

    context 'non-project-repository LFS objects' do
      let_it_be(:nil_lfs_object) { create_linked_lfs_object(project, nil) }
      let_it_be(:wiki_lfs_object) { create_linked_lfs_object(project, :wiki) }
      let_it_be(:design_lfs_object) { create_linked_lfs_object(project, :design) }

      it 'only tries to upload the project-repository LFS object' do
        stub_lfs_batch(nil_lfs_object, lfs_object, upload: false)

        expect(service.execute).to eq(status: :success)
      end
    end
  end

  def create_linked_lfs_object(project, type)
    create(:lfs_objects_project, project: project, repository_type: type).lfs_object
  end

  def stub_lfs_batch(*objects, upload: true)
    expect(lfs_client)
      .to receive(:batch).with('upload', containing_exactly(*objects))
      .and_return('transfer' => 'basic', 'objects' => objects.map { |o| object_spec(o, upload: upload) })
  end

  def batch_spec(*objects, upload: true)
    { 'transfer' => 'basic', 'objects' => objects.map {|o| object_spec(o, upload: upload) } }
  end

  def object_spec(object, upload: true)
    { 'oid' => object.oid, 'size' => object.size, 'authenticated' => true }.tap do |spec|
      spec['actions'] = { 'upload' => upload_action_spec(object) } if upload
    end
  end

  def upload_action_spec(object)
    { 'href' => "https://example.com/#{object.oid}/#{object.size}", 'header' => { 'Key' => 'value' } }
  end
end
