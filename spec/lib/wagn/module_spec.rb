require File.expand_path(File.dirname(__FILE__) + '/../../spec_helper')

describe Wagn::Module do
  context "load_all" do
    it "loads files in the modules directory" do
      begin
        file = "#{RAILS_ROOT}/modules/dummy_spec_module.rb"
        File.open(file, "w") do |f|
          f.write <<-EOF
            class JBob < Wagn::Module
              def self.foo(); "bar"; end
            end
          EOF
        end
        Wagn::Config.config.available_modules << file
        Wagn::Module.load_all
        JBob.foo.should == "bar"
      ensure
        `rm #{file}`
      end
    end
  end
end                                            
