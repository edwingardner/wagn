require File.dirname(__FILE__) + '/../test_helper'

class UserTest < ActiveSupport::TestCase
  # Be sure to include AuthenticatedTestHelper in test/test_helper.rb instead.
  # Then, you can remove it from this and the functional test.
  include AuthenticatedTestHelper
  #fixtures :users

  

  def test_should_reset_password
    User.find_by_email('joe@user.com').update_attributes(:password => 'new password', :password_confirmation => 'new password')
    assert_equal User.find_by_email('joe@user.com'), User.authenticate?('joe@user.com', 'new password')
  end
  
  def test_password_too_short
    assert_no_difference User, :count do
      u=create_user(:password => 'quire', :password_confirmation => 'quire')
      assert !u.valid?
      assert u.errors.on(:password)
    end
  end

  def test_should_create_user
    assert_difference User, :count do
      assert create_user.valid?
    end
  end

  def test_should_require_password
    assert_no_difference User, :count do
      u=create_user(:password => nil)
      assert u.nil? || !u.valid?
      assert u.errors.on(:password)
    end
  end

  def test_should_require_password_confirmation
    assert_no_difference User, :count do
      u = create_user(:password_confirmation => nil)
      assert u.errors.on(:password_confirmation)
    end
  end

  def test_should_require_email
    assert_no_difference User, :count do
      u = create_user(:email => nil)
      assert u.errors.on(:email)
    end
  end
  
  def test_should_downcase_email
    u=create_user(:email=>'QuIrE@example.com')
#require "ruby-debug"
#debugger unless u
#ActiveRecord::Base.logger.info("downcase:\n")
#ActiveRecord::Base.logger.info("downcase: #{u.email}\n")
    assert_equal 'quire@example.com', u.email
  end

  def test_should_not_rehash_password
    User.find_by_email('joe@user.com').update_attributes!(:email => 'joe2@user.com')
    assert_equal User.find_by_email('joe2@user.com'), User.authenticate?('joe2@user.com', 'joe_pass')
  end

  def test_should_authenticate_user
    assert_equal User.find_by_email('joe@user.com'), User.authenticate?('joe@user.com', 'joe_pass')
  end

  def test_should_authenticate_user_with_whitespace
    assert_equal User.find_by_email('joe@user.com'), User.authenticate?(' joe@user.com ', ' joe_pass ')
  end

  def test_should_authenticate_user_with_weird_email_capitalization
    assert User.authenticate?('JOE@user.com', 'joe_pass')
  end
  
  protected
  def create_user(options = {})
    User.create({ :login => 'quire', :email => 'quire@example.com', 
      :password => 'quire1', :password_confirmation => 'quire1',
      :invite_sender_id=>1
    }.merge(options))
  rescue Exception => e;
require "ruby-debug"
debugger
    ActiveRecord::Base.logger.info("Error from create_user:\n#{e.inspect}\n")
    nil
  end
end
