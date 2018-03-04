# encoding: utf-8
require 'net/sftp'
require 'iconv'
require 'csv'

class CsvExporter

  DOWNLOAD_PATH = "#{Rails.root.to_s}/private/data/download"
  UPLOAD_PATH = "#{Rails.root.to_s}/private/data/upload"
  REMOTE_PATH = '/data/files/csv'

  cattr_accessor :import_retry_count

  def initialize
    # Can be created config where we can store such credentials or can store it as Envinroment variables - this is more secure way
    @sftp_server = if Rails.env.production?
                     'csv.example.com/endpoint/'
                   else
                     '0.0.0.0:2020'
                   end
    @sftp_user = "some-ftp-user"
    @path_to_credentials = "path-to-credentials"
    @errors = []
    @import_result = {:error_file => [], :errors => [], success => []}
  end

  cattr_accessor :import_retry_count

  def self.transfer_and_import(send_email = true)
    ftp_transfer(send_email)
  end

  # Transfer csv filles from remote ftp server to local folder
  def self.ftp_transfer(send_email)
    FileUtils.mkdir_p UPLOAD_PATH
    Net::SFTP.start(@sftp_server, @sftp_user, :keys => [@path_to_credentials]) do |sftp|
      # get array of files
      sftp_entries = sftp.dir.entries(REMOTE_PATH).select{ |item| csv_valid?(item) && array.include?(item + ".start")}.sort
      sftp_entries.each do |entry|
        # can be describer constants
        file_local = "#{DOWNLOAD_PATH}/#{entry}"
        file_remote = "#{REMOTE_PATH}/#{entry}"

        sftp.download!(file_remote, file_local)
        # remove only if download was successful
        sftp.remove!(file_remote + '.start')
        data_import(file_local, entry)
      end
    end
    send_import_report(send_email)
  end

  def self.data_import(file_local, entry)
    result = import(file_local)
    if result == 'Success'
      File.delete(file_local)
      @import_result[:success] << entry
    else
      @import_result[:error_file] << entry
      @import_result[:errors] << result
      upload_error_file(entry, error_content)
    end
  end

  def self.send_import_report(send_email)
    if send_email
      if @import_result.success.length > 0
        @import_result.success.map!{|success| "Import of the file #{success} done."}
        BackendMailer.send_import_feedback('Successful Import', @import_result.success.join("\n"))
      end
      if @import_result[:error_file].length > 0
        get_error_message_and_upload
        BackendMailer.send_import_feedback('Import CSV failed',error_messages.join("\n"))
      end
    end
  end


  def self.import(file, validation_only = false)
    begin
      result = import_file(file, validation_only)
    rescue => e
      result = { :errors => [e.to_s], :success => ['data lost'] }
    end

    if result[:errors].blank?
      result = "Success"
    else
      result = "Imported: #{result[:success].join(', ')} Errors: #{result[:errors].join('; ')}"
    end

    Rails.logger.info "CsvExporter#import time: #{Time.now.to_formatted_s(:db)} Imported #{file}: #{result}"

    result
  end

  def self.import_file(file, validation_only = false)
    @errors = []
    line = 2
    source_path = "#{Rails.root.to_s}/private/upload"
    path_and_name = "#{source_path}/csv/tmp_mraba/DTAUS#{Time.now.strftime('%Y%m%d_%H%M%S')}"

    FileUtils.mkdir_p "#{source_path}/csv"
    FileUtils.mkdir_p "#{source_path}/csv/tmp_mraba"

    @dtaus = Mraba::Transaction.define_dtaus('RS', 8888888888, 99999999, 'Credit collection')
    success_rows = []
    import_rows = CSV.read(file, { :col_sep => ';', :headers => true, :skip_blanks => true } ).map{ |r| [r.to_hash['ACTIVITY_ID'], r.to_hash] }

    import_rows.each do |index, row|
      next if index.blank?
      break unless validate_import_row?(row)
      errors, dtaus = import_file_row_with_error_handling(row, validation_only, @errors, @dtaus)
      line += 1
      break unless @errors.empty?
      success_rows << row['ACTIVITY_ID']
    end

    if @errors.empty? and !validation_only
      @dtaus.add_datei("#{path_and_name}_201_mraba.csv") unless @dtaus.is_empty?
    end

    {:success => success_rows, :errors => @errors}
  end

  def self.import_file_row(row, validation_only, errors, dtaus)
    case transaction_type(row)
      when 'AccountTransfer' then add_account_transfer(row, validation_only)
      when 'BankTransfer' then add_bank_transfer(row, validation_only)
      when 'Lastschrift' then add_dta_row(dtaus, row, validation_only)
      else add_error("#{row['ACTIVITY_ID']}: Transaction type not found")
    end

    [errors, dtaus]
  end

  def self.import_file_row_with_error_handling(row, validation_only, errors, dtaus)
    error_text = nil
    self.import_retry_count = 0
    5.times do
      self.import_retry_count += 1
      error_text = nil
      begin
        import_file_row(row, validation_only, errors, dtaus)
        break
      rescue => e
        error_text = "#{row['ACTIVITY_ID']}: #{e.to_s}"
        break
      end
    end
    errors << error_text if error_text

    [errors, dtaus]
  end

  def self.validate_import_row?(row)
    return if %w[10 16].include?row['UMSATZ_KEY']
    add_error("#{row['ACTIVITY_ID']}: UMSATZ_KEY #{row['UMSATZ_KEY']} is not allowed")
    false
  end

  def self.transaction_type(row)
    if row['SENDER_BLZ'] == '00000000' and row['RECEIVER_BLZ'] == '00000000'
      return 'AccountTransfer'
    elsif row['SENDER_BLZ'] == '00000000' and row['UMSATZ_KEY'] == '10'
      return 'BankTransfer'
    elsif row['RECEIVER_BLZ'] == '70022200' and ['16'].include?row['UMSATZ_KEY']
      return 'Lastschrift'
    else
      return false
    end
  end

  def self.get_sender(row)
    sender = Account.find_by_account_no(row['SENDER_KONTO'])

    if sender.nil?
      add_error("#{row['ACTIVITY_ID']}: Account #{row['SENDER_KONTO']} not found")
    end

    sender
  end

  def self.account_transfer(row)
    sender = get_sender(row)
    return @errors.last unless sender
    @account_transfer ||= if row.depot_activity_id.blank?
                            build_account_transfer(row)
                          else
                            find_account_transfer(row)
                          end
  end

  def self.build_account_transfer(row)
    sender.credit_account_transfers.build(
      amount: row['AMOUNT'].to_f,
      subject: import_subject(row),
      receiver_multi: row['RECEIVER_KONTO'],
      date: row['ENTRY_DATE'].to_date,
      skip_mobile_tan: true
    )
  end

  def self.find_account_transfer(row)
    account_transfer = sender.credit_account_transfers.find_by_id(row['DEPOT_ACTIVITY_ID'])
    if account_transfer.nil?
      add_error("#{row['ACTIVITY_ID']}: AccountTransfer not found")
      return
    elsif account_transfer.state != 'pending'
      add_error("#{row['ACTIVITY_ID']}: AccountTransfer state expected 'pending' but was '#{account_transfer.state}'")
      return
    else
      account_transfer.subject = import_subject(row)
    end
    account_transfer_valid(account_transfer, row)
  end

  def self.account_transfer_valid(account_transfer, row)
    if account_transfer && !account_transfer.valid?
      add_error("#{row['ACTIVITY_ID']}: AccountTransfer validation error(s): #{account_transfer.errors.full_messages.join('; ')}")
    elsif !validation_only
      row['DEPOT_ACTIVITY_ID'].blank? ? account_transfer.save! : account_transfer.complete_transfer!
    end
  end

  def self.add_bank_transfer(row, validation_only)
    sender = get_sender(row)
    return @errors.last unless sender

    bank_transfer = sender.build_transfer(
      :amount => row['AMOUNT'].to_f,
      :subject => import_subject(row),
      :rec_holder => row['RECEIVER_NAME'],
      :rec_account_number => row['RECEIVER_KONTO'],
      :rec_bank_code => row['RECEIVER_BLZ']
    )

    if !bank_transfer.valid?
      add_error("#{row['ACTIVITY_ID']}: BankTransfer validation error(s): #{bank_transfer.errors.full_messages.join('; ')}")
    elsif !validation_only
      bank_transfer.save!
    end
  end

  def self.add_dta_row(dtaus, row, validation_only)
    if !dtaus.valid_sender?(row['SENDER_KONTO'],row['SENDER_BLZ'])
      return @errors << "#{row['ACTIVITY_ID']}: BLZ/Konto not valid, csv fiile not written"
    end
    holder = Iconv.iconv('ascii//translit', 'utf-8', row['SENDER_NAME']).to_s.gsub(/[^\w^\s]/, '')
    dtaus.add_buchung(row['SENDER_KONTO'], row['SENDER_BLZ'], holder, BigDecimal(row['AMOUNT']).abs, import_subject(row))
  end

  def self.import_subject(row)
    subject = ""

    for id in (1..14).to_a
      subject += row["DESC#{id}"].to_s unless row["DESC#{id}"].blank?
    end

    subject
  end

  private

  def self.upload_error_file(entry, result)
    error_file = "#{UPLOAD_PATH}/#{entry}"
    File.open(error_file, "w") do |f|
      f.write(result)
    end
    Net::SFTP.start(@sftp_server, @sftp_user, :keys => [@path_to_credentials]) do |sftp|
      sftp.upload!(error_file, "/data/files/batch_processed/#{entry}")
    end
  end

  def self.csv_valid?(file_name)
    file_name[-4, 4] == ".csv"
  end

  def self.get_error_message_and_upload
    error_messages = []
    @import_result[:error_file].each do |file, index|
      upload_error_file(file, @import_result[:errors][index])
      error_messages << ["Import of the file #{file} failed with errors:", @import_result[:errors][index]].join("\n")
    end
    error_messages
  end

  def add_error(error)
    @errors << error
  end

end

