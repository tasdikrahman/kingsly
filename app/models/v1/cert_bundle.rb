class V1::CertBundle < ApplicationRecord
  validates_uniqueness_of :sub_domain, scope: :top_level_domain
  validates_presence_of :sub_domain, :top_level_domain

  def obtain_or_renew
    self.errors.add(:sub_domain, message: "Cannot be empty") and return if sub_domain.nil?
    self.errors.add(:top_level_domain, message: "Cannot be empty") and return if top_level_domain.nil?

    begin
      fqdn = "#{sub_domain}.#{top_level_domain}"

      acme_service = AcmeService.new
      acme_service.create_order(fqdn)
      dns_challenge = acme_service.dns_challenge

      AwsService.new.update_route53_record!(
        top_level_domain,
        "#{dns_challenge.record_name}.#{fqdn}",
        "\"#{dns_challenge.record_content}\"",
        dns_challenge.record_type,
      )

      acme_service.perform_validation!
      cert_bundle = acme_service.request_certificate!(fqdn)

      update(
        private_key: cert_bundle[:private_key],
        full_chain: cert_bundle[:full_chain],
      )
    rescue Aws::Waiters::Errors::WaiterFailed => error
      Rails.logger.error("[FAILED] AWS route53 record creation: #{error.message}")
      self.errors.add(:route53_updation_failed, message: "#{error.message}")
    rescue StandardError => error
      Rails.logger.error("[FAILED] Standard Error: #{error.message}")
      self.errors.add(:standard_error, message: "#{error.message}")
    end
  end
end
