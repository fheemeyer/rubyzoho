$:.unshift File.join('..', File.dirname(__FILE__), 'lib')

require 'httmultiparty'
require 'rexml/document'
require 'net/http/post/multipart'
require 'net/https'
require 'mime/types'
require 'ruby_zoho'
require 'yaml'
require 'api_utils'
require 'zoho_api_field_utils'
require 'zoho_api_finders'

module ZohoApi


  include ApiUtils

  class Crm

    include HTTMultiParty
    include ZohoApiFieldUtils
    include ZohoApiFinders

    #debug_output $stderr

    attr_reader :auth_token, :module_fields

    def initialize(auth_token, modules, ignore_fields, fields = nil)
      @auth_token = auth_token
      @modules = %w(Accounts Contacts Events Leads Potentials Tasks Users).concat(modules).uniq
      @module_fields = fields.nil? ? reflect_module_fields : fields
      @ignore_fields = ignore_fields
    end

    def add_record(module_name, fields_values_hash)
      x = REXML::Document.new
      element = x.add_element module_name
      row = element.add_element 'row', { 'no' => '1' }
      fields_values_hash.each_pair { |k, v| add_field(row, ApiUtils.symbol_to_string(k), v) }
      r = self.class.post(create_url(module_name, 'insertRecords'),
                          :query => { :newFormat => 1, :authtoken => @auth_token,
                                      :scope => 'crmapi', :xmlData => x },
                          :headers => { 'Content-length' => '0' })
      check_for_errors(r)
      x_r = REXML::Document.new(r.body).elements.to_a('//recorddetail')
      to_hash(x_r, module_name)[0]
    end

    def attach_file(module_name, record_id, file_path, file_name)
      mime_type = (MIME::Types.type_for(file_path)[0] || MIME::Types['application/octet-stream'][0])
      url_path = create_url(module_name, "uploadFile?authtoken=#{@auth_token}&scope=crmapi&id=#{record_id}")
      url = URI.parse(create_url(module_name, url_path))
      io = UploadIO.new(file_path, mime_type, file_name)
      req = Net::HTTP::Post::Multipart.new url_path, 'content' => io
      http = Net::HTTP.new(url.host, url.port)
      http.use_ssl = true
      res = http.start do |h|
        h.request(req)
      end
      raise(RuntimeError, "[RubyZoho] Attach of file #{file_path} to module #{module_name} failed.") unless res.code == '200'
      res.code
    end

    def check_for_errors(response)
      raise(RuntimeError, "Web service call failed with #{response.code}") unless response.code == 200
      x = REXML::Document.new(response.body)
      code = REXML::XPath.first(x, '//code')
      raise(RuntimeError, "Zoho Error Code #{code.text}: #{REXML::XPath.first(x, '//message').text}.") unless code.nil? || ['4422', '5000'].index(code.text)
      return code.text unless code.nil?
      response.code
    end

    def create_url(module_name, api_call)
      "https://crm.zoho.com/crm/private/xml/#{module_name}/#{api_call}"
    end

    def delete_record(module_name, record_id)
      post_action(module_name, record_id, 'deleteRecords')
    end

    def first(module_name)
      some(module_name, 1, 1)
    end

    def find_records(module_name, field, condition, value)
      sc_field = field == :id ? primary_key(module_name) : ApiUtils.symbol_to_string(field)
      return find_record_by_related_id(module_name, sc_field, value) if related_id?(module_name, sc_field)
      primary_key?(module_name, sc_field) == false ? find_record_by_field(module_name, sc_field, condition, value) :
          find_record_by_id(module_name, value)
    end

    def find_record_by_field(module_name, sc_field, condition, value)
      field = sc_field.rindex('id') ? sc_field.downcase : sc_field
      search_condition = '(' + field + '|' + condition + '|' + value + ')'
      r = self.class.get(create_url("#{module_name}", 'getSearchRecords'),
                         :query => {:newFormat => 1, :authtoken => @auth_token, :scope => 'crmapi',
                                    :selectColumns => 'All', :searchCondition => search_condition,
                                    :fromIndex => 1, :toIndex => NUMBER_OF_RECORDS_TO_GET})
      check_for_errors(r)
      x = REXML::Document.new(r.body).elements.to_a("/response/result/#{module_name}/row")
      to_hash(x, module_name)
    end

    def find_record_by_id(module_name, id)
      r = self.class.get(create_url("#{module_name}", 'getRecordById'),
         :query => { :newFormat => 1, :authtoken => @auth_token, :scope => 'crmapi',
                     :selectColumns => 'All', :id => id})
      raise(RuntimeError, 'Bad query', "#{module_name} #{id}") unless r.body.index('<error>').nil?
      check_for_errors(r)
      x = REXML::Document.new(r.body).elements.to_a("/response/result/#{module_name}/row")
      to_hash(x, module_name)
    end

    def find_record_by_related_id(module_name, sc_field, value)
      raise(RuntimeError, "[RubyZoho] Not a valid query field #{sc_field} for module #{module_name}") unless
          valid_related?(module_name, sc_field)
      field = sc_field.downcase
      r = self.class.get(create_url("#{module_name}", 'getSearchRecordsByPDC'),
         :query => { :newFormat => 1, :authtoken => @auth_token, :scope => 'crmapi',
             :selectColumns => 'All', :version => 2, :searchColumn => field,
             :searchValue => value})
      check_for_errors(r)
      x = REXML::Document.new(r.body).elements.to_a("/response/result/#{module_name}/row")
      to_hash(x, module_name)
    end

    def get_records_from_custom_view(module_name, custom_view_name, from_index, to_index)
      r = self.class.get(create_url("#{module_name}", 'getCVRecords'),
         :query => { :newFormat => 1, :authtoken => @auth_token, :scope => 'crmapi',
                     :cvName => custom_view_name, :fromIndex => from_index, :toIndex => to_index})
      raise(RuntimeError, 'Bad query', "#{module_name} #{id}") unless r.body.index('<error>').nil?
      check_for_errors(r)
      x = REXML::Document.new(r.body).elements.to_a("/response/result/#{module_name}/row")
      to_hash(x, module_name)
    end

    def method_name?(n)
      return /[@$"]/ !~ n.inspect
    end

    def post_action(module_name, record_id, action_type)
      r = self.class.post(create_url(module_name, action_type),
                          :query => { :newFormat => 1, :authtoken => @auth_token,
                                      :scope => 'crmapi', :id => record_id },
                          :headers => { 'Content-length' => '0' })
      raise('Adding contact failed', RuntimeError, r.response.body.to_s) unless r.response.code == '200'
      check_for_errors(r)
    end

    def primary_key(module_name)
      activity_keys = { 'Tasks' => :activityid, 'Events' => :activityid, 'Calls' => :activityid }
      return activity_keys[module_name] unless activity_keys[module_name].nil?
      (module_name.downcase.chop + 'id').to_sym
    end

    def primary_key?(module_name, field_name)
      return nil if field_name.nil? || module_name.nil?
      fn = field_name.class == String ? field_name : field_name.to_s
      return true if fn == 'id'
      return true if %w[Calls Events Tasks].index(module_name) && fn.downcase == 'activityid'
      fn.downcase.gsub('id', '') == module_name.chop.downcase
    end

    def related_id?(module_name, field_name)
      field = field_name.to_s
      return false if field.rindex('id').nil?
      return false if %w[Calls Events Tasks].index(module_name) && field_name.downcase == 'activityid'
      field.downcase.gsub('id', '') != module_name.chop.downcase
    end

    def related_records(parent_module, parent_record_id, related_module)
      r = self.class.get(create_url("#{related_module}", 'getRelatedRecords'),
                         :query => { :newFormat => 1, :authtoken => @auth_token, :scope => 'crmapi',
                                     :parentModule => parent_module, :id => parent_record_id })

      x = REXML::Document.new(r.body).elements.to_a("/response/result/#{parent_module}/row")
      check_for_errors(r)
    end

    def some(module_name, index = 1, number_of_records = nil)
      r = self.class.get(create_url(module_name, 'getRecords'),
                         :query => { :newFormat => 2, :authtoken => @auth_token, :scope => 'crmapi',
                                     :fromIndex => index, :toIndex => number_of_records || NUMBER_OF_RECORDS_TO_GET })
      return nil unless r.response.code == '200'
      check_for_errors(r)
      x = REXML::Document.new(r.body).elements.to_a("/response/result/#{module_name}/row")
      to_hash(x, module_name)
    end

    def update_record(module_name, id, fields_values_hash)
      x = REXML::Document.new
      contacts = x.add_element module_name
      row = contacts.add_element 'row', { 'no' => '1' }
      fields_values_hash.each_pair { |k, v| add_field(row, ApiUtils.symbol_to_string(k), v) }
      r = self.class.post(create_url(module_name, 'updateRecords'),
                          :query => { :newFormat => 1, :authtoken => @auth_token,
                                      :scope => 'crmapi', :id => id,
                                      :xmlData => x },
                          :headers => { 'Content-length' => '0' })
      check_for_errors(r)
      x_r = REXML::Document.new(r.body).elements.to_a('//recorddetail')
      to_hash_with_id(x_r, module_name)[0]
    end

    def update_records(module_name, objects)
      x = REXML::Document.new
      data = x.add_element module_name
      count = 0
      objects.each do |fields_values_hash|
        count = count + 1
        row = data.add_element('row', {'no' => count})
        fields_values_hash.each_pair { |k, v| add_field(row, ApiUtils.symbol_to_string(k), v) }
      end
      r = self.class.post(create_url(module_name, 'updateRecords'),
          :query => { :authtoken => @auth_token,
                      :scope => 'crmapi', :version => 4,
                      :xmlData => x })
      check_for_errors(r)
      x_r = REXML::Document.new(r.body).elements.to_a('//recorddetail')
      to_hash_with_id(x_r, module_name)[0]
    end

    def user_fields
      @@module_fields[:users] = users[0].keys
    end

    def users(user_type = 'AllUsers')
      return @@users unless @@users == [] || user_type == 'Refresh'
      r = self.class.get(create_url('Users', 'getUsers'),
                         :query => { :newFormat => 1, :authtoken => @auth_token, :scope => 'crmapi',
                                     :type => 'AllUsers' })
      check_for_errors(r)
      result = extract_users_from_xml_response(r)
      @@users = result
    end

    def extract_users_from_xml_response(response)
      x = REXML::Document.new(response.body).elements.to_a('/users')
      result = []
      x.each do |e|
        e.elements.to_a.each do |node|
          record = extract_user_name_and_attribs(node)
          result << record
        end
      end
      result
    end

    def extract_user_name_and_attribs(node)
      record = {}
      record.merge!({ :user_name => node.text })
      node.attributes.each_pair do |k, v|
        record.merge!({ k.to_s.to_sym => v.to_string.match(/'(.*?)'/).to_s.gsub('\'', '') })
      end
      record
    end

    def valid_related?(module_name, field)
      return nil if field.downcase == 'smownerid'
      valid_relationships = {
          'Leads' => %w(email),
          'Accounts' => %w(accountid accountname),
          'Contacts' => %w(contactid accountid vendorid email),
          'Potentials' => %w(potentialid accountid campaignid contactid potentialname),
          'Campaigns' => %w(campaignid campaignname),
          'Cases' => %w(caseid productid accountid potentialid),
          'Solutions' => %w(solutionid productid),
          'Products' => %w(productid vendorid productname),
          'Purchase Order' => %w(purchaseorderid contactid vendorid),
          'Quotes' => %w(quoteid potentialid accountid contactid),
          'Sales Orders' => %w(salesorderid potentialid accountid contactid quoteid),
          'Invoices' => %w(invoiceid accountid salesorderid contactid),
          'Vendors' => %w(vendorid vendorname),
          'Tasks' => %w(taskid),
          'Events' => %w(eventid),
          'Notes' => %w(notesid)
      }
      valid_relationships[module_name].index(field.downcase)
    end

  end

end

