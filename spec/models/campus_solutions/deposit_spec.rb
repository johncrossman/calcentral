require 'spec_helper'

describe CampusSolutions::Deposit do

  shared_examples 'a proxy that gets data' do
    subject { proxy.get }
    it_should_behave_like 'a simple proxy that returns errors'
    it_behaves_like 'a proxy that properly observes the profile feature flag'
    it_behaves_like 'a proxy that got data successfully'
    it 'returns data with the expected structure' do
      expect(subject[:feed][:depositResponse]).to be
      expect(subject[:feed][:depositResponse][:deposit][:emplid]).to be
    end
  end

  context 'mock proxy' do
    let(:proxy) { CampusSolutions::Deposit.new(fake: true, adm_appl_nbr: '00000087') }
    it_should_behave_like 'a proxy that gets data'
    subject { proxy.get }
    it 'should get specific mock data' do
      expect(subject[:feed][:depositResponse][:deposit][:emplid]).to eq '24188949'
      expect(subject[:feed][:depositResponse][:deposit][:dueDt]).to eq '2015-09-01'
    end
  end

  # ignore until auth is in place for UCBCALCENTRAL
  context 'real proxy', ignore: true, testext: true do
    let(:proxy) { CampusSolutions::Deposit.new(fake: false, adm_appl_nbr: '00000087') }
    it_should_behave_like 'a proxy that gets data'
  end

end
