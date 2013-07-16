module Bosh::Cloudfoundry
  # Prior to deploying (creating or updating or deleting) a bosh release we
  # need a deployment file. This is created with this class +DeploymentFile+.
  #
  # The deployment file is a product of:
  # * a release version/CPI/size (+ReleaseVersionCpiSize+) which provides a template; and
  # * attributes (+DeploymentAttributes+) which populate the template
  class DeploymentFile
    include FileUtils
    include Bosh::Cli::Validation

    attr_reader :release_version_cpi_size
    attr_reader :deployment_attributes
    attr_reader :bosh_status

    def initialize(release_version_cpi_size, deployment_attributes, bosh_status)
      @release_version_cpi_size = release_version_cpi_size
      @deployment_attributes = deployment_attributes
      @bosh_status = bosh_status
    end

    def prepare_environment
      step("Checking/creating #{deployment_file_dir} for deployment files",
           "Failed to create #{deployment_file_dir} for deployment files", :fatal) do
        mkdir_p(deployment_file_dir)
      end
    end

    # Create an initial deployment file; upon which the CPI-specific template will be applied below
    # Initial file will look like:
    # ---
    # name: NAME
    # director_uuid: 4ae3a0f0-70a5-4c0d-95f2-7fafaefe8b9e
    # releases:
    #  - name: cf-release
    #    version: 132
    # networks: {}
    # properties:
    #   cf:
    #     dns: mycloud.com
    #     ip_addresses: ['1.2.3.4']
    #     deployment_size: medium
    #     security_group: cf
    #     persistent_disk: 4096
    #
    # It is then merged with the corresponding template from +release_version_cpi_size+.
    def create_deployment_file
      step("Creating deployment file #{deployment_file}",
           "Failed to create deployment file #{deployment_file}", :fatal) do
        File.open(deployment_file, "w") do |file|
          file << {
            "name" => deployment_attributes.name,
            "director_uuid" => bosh_uuid,
            "releases" => {
              "name" => release_name,
              "version" => release_version_number
            },
            "networks" => {},
            "properties" => {
              self.class.properties_key => deployment_attributes.attributes_with_string_keys
            }
          }.to_yaml
        end

        quieten_output do
          deployment_cmd(non_interactive: true).set_current(deployment_file)
          biff_cmd(non_interactive: true).biff(template_file)
        end
      end
    rescue Bosh::Cli::ValidationHalted
      errors.each do |error|
        say error.make_red
      end
    end

    # Perform the create/update deployment described by this +DeploymentFile+
    def deploy(options={})
      # set current deployment to show the change in the output
      deployment_cmd.set_current(deployment_file)
      deployment_cmd(non_interactive: options[:non_interactive]).perform
    end

    # The trio of DeploymentFile, DeploymentAttributes & ReleaseVersionCpiSize can be
    # reconstructed from a deployment file that was previously generated by this class.
    #
    # Specifically, it requires the deployment file to look like:
    # ---
    # name: NAME
    # releases:
    #  - name: cf-release
    #    version: 132
    # properties:
    #   cf:
    #     dns: mycloud.com
    #     ip_addresses: ['1.2.3.4']
    #     deployment_size: medium
    #     security_group: cf
    #     persistent_disk: 4096
    def self.reconstruct_from_deployment_file(deployment_file_path, director_client, bosh_status)
      deployment_file = YAML.load_file(deployment_file_path)
      bosh_cpi = bosh_status["cpi"]

      release = deployment_file["releases"].find do |release|
        release["name"] == "cf" || release["name"] == "cf-release"
      end
      release_version = release["version"]
      release_version_cpi = ReleaseVersionCpi.new(release_version, bosh_cpi)
      deployment_size = deployment_file["properties"]["deployment_size"]
      release_version_cpi_size = ReleaseVersionCpiSize.new(release_version_cpi, deployment_size)

      attributes = deployment_file["properties"][properties_key]
      # convert string keys to symbol keys
      attributes = attributes.inject({}) do |mem, key_value|
        k, v = key_value; mem[k.to_sym] = v; mem
      end
      deployment_attributes = DeploymentAttributes.new(director_client, bosh_status, release_version_cpi, attributes)

      self.new(release_version_cpi_size, deployment_attributes, bosh_status)
    end

    def release_name
      release_version_cpi_size.release_name
    end

    def release_version_number
      release_version_cpi_size.release_version_number
    end

    def deployment_size
      deployment_attributes.deployment_size
    end

    def deployment_file
      File.join(deployment_file_dir, "#{deployment_attributes.name}.yml")
    end

    def deployment_file_dir
      File.expand_path("deployments/cf")
    end

    def template_file
      release_version_cpi_size.template_file_path
    end

    def deployment_cmd(options = {})
      cmd ||= Bosh::Cli::Command::Deployment.new
      options.each do |key, value|
        cmd.add_option key.to_sym, value
      end
      cmd
    end

    def release_cmd(options = {})
      cmd ||= Bosh::Cli::Command::Release.new
      options.each do |key, value|
        cmd.add_option key.to_sym, value
      end
      cmd
    end

    def biff
      @biff_cmd ||= Bosh::Cli::Command::Biff.new
    end

    def biff_cmd(options = {})
      options.each do |key, value|
        biff.add_option key.to_sym, value
      end
      biff
    end

    def bosh_uuid
      bosh_status["uuid"]
    end

    def bosh_cpi
      bosh_status["cpi"]
    end

    # attributes are stored within deployment file at properties.cf
    def self.properties_key
      "cf"
    end

    def quieten_output(&block)
      stdout = Bosh::Cli::Config.output
      Bosh::Cli::Config.output = nil
      yield
      Bosh::Cli::Config.output = stdout
    end
  end
end