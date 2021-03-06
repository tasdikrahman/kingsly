require 'rails_helper'

RSpec.describe V1::CertBundle, type: :model do
  it { should validate_uniqueness_of(:sub_domain).scoped_to(:top_level_domain) }
  it { should validate_presence_of(:sub_domain) }
  it { should validate_presence_of(:top_level_domain) }

  before :each do
    V1::CertBundle.destroy_all
  end

  describe "#obtain_or_renew" do
    let(:sub_domain) { "foo" }
    let(:top_level_domain) { "test.com" }
    let(:fqdn) { "#{sub_domain}.#{top_level_domain}" }

    let(:dns_challenge_record_name) { "_acme_challenge" }
    let(:dns_challenge_record_type) { "TXT" }
    let(:dns_challenge_record_content) { "dns_challenge_content" }

    let(:private_key) { "-----BEGIN RSA PRIVATE KEY-----\nFOO...\n-----END RSA PRIVATE KEY-----\n" }
    let(:full_chain) { "-----BEGIN CERTIFICATE-----\nBAR...\n-----END CERTIFICATE-----\n" }

    it "obtains a cert and stores to DB" do
      cert_bundle = V1::CertBundle.new(sub_domain: sub_domain, top_level_domain: top_level_domain)

      acme_service_dbl = double(AcmeService)
      expect(AcmeService).to receive(:new).and_return(acme_service_dbl)
      expect(acme_service_dbl).to receive(:create_order).with(fqdn)

      dns_challenge_double = double
      expect(acme_service_dbl).to receive(:dns_challenge).and_return(dns_challenge_double)
      expect(dns_challenge_double).to receive(:record_name).and_return(dns_challenge_record_name)
      expect(dns_challenge_double).to receive(:record_type).and_return(dns_challenge_record_type)
      expect(dns_challenge_double).to receive(:record_content).and_return(dns_challenge_record_content)

      aws_service_dbl = double(AwsService)
      expect(AwsService).to receive(:new).and_return(aws_service_dbl)
      expect(aws_service_dbl).to receive(:update_route53_record!).with(
        top_level_domain,
        "#{dns_challenge_record_name}.#{fqdn}",
        "\"#{dns_challenge_record_content}\"",
        dns_challenge_record_type,
      )

      expect(acme_service_dbl).to receive(:perform_validation!)
      expect(acme_service_dbl).to receive(:request_certificate!).with(fqdn)
        .and_return({private_key: private_key, full_chain: full_chain})

      cert_bundle.obtain_or_renew

      persisted_cert_bundle = V1::CertBundle.find_by(sub_domain: sub_domain, top_level_domain: top_level_domain)
      expect(persisted_cert_bundle.private_key).to eq(private_key)
      expect(persisted_cert_bundle.full_chain).to eq(full_chain)
    end

    context "when certs are already present for given sub domain and top level domain" do
      let(:renewed_private_key) { "renewd private key" }
      let(:renewed_full_chain) { "renewed full chain" }

      it "renews and stores updated certs to DB" do
        cert_bundle = V1::CertBundle.create(sub_domain: sub_domain, top_level_domain: top_level_domain, private_key: private_key, full_chain: full_chain)

        acme_service_dbl = double(AcmeService)
        expect(AcmeService).to receive(:new).and_return(acme_service_dbl)
        expect(acme_service_dbl).to receive(:create_order).with(fqdn)

        dns_challenge_double = double
        expect(acme_service_dbl).to receive(:dns_challenge).and_return(dns_challenge_double)
        expect(dns_challenge_double).to receive(:record_name).and_return(dns_challenge_record_name)
        expect(dns_challenge_double).to receive(:record_type).and_return(dns_challenge_record_type)
        expect(dns_challenge_double).to receive(:record_content).and_return(dns_challenge_record_content)

        aws_service_dbl = double(AwsService)
        expect(AwsService).to receive(:new).and_return(aws_service_dbl)
        expect(aws_service_dbl).to receive(:update_route53_record!).with(
          top_level_domain,
          "#{dns_challenge_record_name}.#{fqdn}",
          "\"#{dns_challenge_record_content}\"",
          dns_challenge_record_type,
        )

        expect(acme_service_dbl).to receive(:perform_validation!)
        expect(acme_service_dbl).to receive(:request_certificate!).with(fqdn)
          .and_return({private_key: renewed_private_key, full_chain: renewed_full_chain})

        cert_bundle.obtain_or_renew

        renewed_cert_bundle = V1::CertBundle.find_by(sub_domain: sub_domain, top_level_domain: top_level_domain)
        expect(renewed_cert_bundle.private_key).to eq(renewed_private_key)
        expect(renewed_cert_bundle.full_chain).to eq(renewed_full_chain)
      end
    end

    context "when AWS route53 updation failed" do
      it "returns error" do
        cert_bundle = V1::CertBundle.new(sub_domain: sub_domain, top_level_domain: top_level_domain)

        acme_service_dbl = double(AcmeService)
        expect(AcmeService).to receive(:new).and_return(acme_service_dbl)
        expect(acme_service_dbl).to receive(:create_order)

        dns_challenge_double = double
        expect(acme_service_dbl).to receive(:dns_challenge).and_return(dns_challenge_double)
        expect(dns_challenge_double).to receive(:record_name)
        expect(dns_challenge_double).to receive(:record_type)
        expect(dns_challenge_double).to receive(:record_content)

        aws_service_dbl = double(AwsService)
        expect(AwsService).to receive(:new).and_return(aws_service_dbl)
        expect(aws_service_dbl).to receive(:update_route53_record!).and_raise(Aws::Waiters::Errors::WaiterFailed)

        cert_bundle.obtain_or_renew

        expect(cert_bundle.errors.full_messages).to eq(["Route53 updation failed {:message=>\"Aws::Waiters::Errors::WaiterFailed\"}"])
      end
    end

    context "when random errors occur" do
      it "returns error" do
        cert_bundle = V1::CertBundle.new(sub_domain: sub_domain, top_level_domain: top_level_domain)

        expect(AcmeService).to receive(:new).and_raise("random error")

        cert_bundle.obtain_or_renew

        expect(cert_bundle.errors.full_messages).to eq(["Standard error {:message=>\"random error\"}"])
      end
    end

    context "when sub domain is not set" do
      it "returns an error" do
        cert_bundle = V1::CertBundle.new
        cert_bundle.obtain_or_renew
        expect(cert_bundle.errors.full_messages).to eq(["Sub domain {:message=>\"Cannot be empty\"}"])
      end
    end

    context "when TLD is not set" do
      it "returns an error" do
        cert_bundle = V1::CertBundle.new(sub_domain: sub_domain)
        cert_bundle.obtain_or_renew
        expect(cert_bundle.errors.full_messages).to eq(["Top level domain {:message=>\"Cannot be empty\"}"])
      end
    end
  end
end
