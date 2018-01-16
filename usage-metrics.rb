#!/usr/bin/env ruby
require 'json'
require 'date'
require 'gmail'
require 'excon'
require 'trollop'
require 'pry'

opts = Trollop::options do
  opt :gmail_user, "GMail username", :type => :string
  opt :gmail_pass, "GMail password", :type => :string
  opt :kairos_ip, "KairosDB host", :type => :string
  opt :kairos_port, "KairosDB port", :default => 8080
  opt :label, "Mailbox or label. eg. 'Inbox', 'All Mail'... Default: 'usages' ", :type => :string, :default => "usages"
  opt :customer, "Only search this customer.", :type => :string
end
unless opts[:lookup]
  Trollop::die "GMail access credentials not present." if opts[:gmail_user].nil? or opts[:gmail_pass].nil?
  Trollop::die "Need KairosDB host and port." if opts[:kairos_ip].nil? or opts[:kairos_port].nil?
end

connection = Excon.new("http://#{opts[:kairos_ip]}:#{opts[:kairos_port]}/api/v1/datapoints")
gmail = Gmail.new(opts[:gmail_user], opts[:gmail_pass])

mailbox = gmail.mailbox(opts[:label])
uids = mailbox.fetch_uids
uids.each do |uid|
  gmail_email = Gmail::Message.new(mailbox, uid)
  mail = gmail_email.message
  subj = mail.subject
  next unless subj.include? opts[:customer] if opts[:customer]
  body = mail.body.to_s
  body.gsub!(/WARNING!\nCustimer with IP address:.*is using an OUTDATED version of abiquo-usage binary. Request an UPDATE ASAP./, "")
  begin
    bodyh = JSON.parse(body.to_s)
  rescue JSON::ParserError => e
    puts "Skipping"
    puts e.message
    puts e.backtrace
    next
  end
  customer = subj.split(": ").last.split("[").first.chomp(" ").chomp(".")
  date_ms = DateTime.parse(bodyh["ExecutionTime"]).to_time.to_i * 1000

  puts "Mail from #{bodyh["ExecutionTime"]} from customer #{customer}, with #{bodyh['totalVMs']} VMs."
  bodyh.keys.each do |k|
    next if k == "ExecutionTime" or k.start_with? "License" or k == "CheckVersion"
    metric_name = "#{customer}_#{k}"
    
    value = {
      "name" => metric_name,
      "timestamp" => date_ms,
      "tags" => { "customer" => customer },
      "value" => bodyh[k].to_i
    }

    puts "Posting: #{value.to_json}"
    resp = connection.post(:path => "/api/v1/datapoints", :body => value.to_json)
    if resp.status != 204
      puts "Kairos response status #{resp.status}"
      puts resp.body
      exit(1)
    end
  end
end
