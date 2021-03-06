# Copyright 2017 Google Inc. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


require "base64"
require "openssl"
require "google/cloud/storage/errors"

module Google
  module Cloud
    module Storage
      class File
        ##
        # @private Create a signed_url for a file.
        class Signer
          def initialize bucket, path, service
            @bucket = bucket
            @path = path
            @service = service
          end

          def self.from_file file
            new file.bucket, file.name, file.service
          end

          def self.from_bucket bucket, path
            new bucket.name, path, bucket.service
          end

          ##
          # The external path to the file.
          def ext_path
            URI.escape "/#{@bucket}/#{@path}"
          end

          ##
          # The external url to the file.
          def ext_url
            "#{GOOGLEAPIS_URL}#{ext_path}"
          end

          def apply_option_defaults options
            adjusted_expires = (Time.now.utc + (options[:expires] || 300)).to_i
            options[:expires] = adjusted_expires
            options[:method]  ||= "GET"
            options
          end

          def signature_str options
            [options[:method], options[:content_md5],
             options[:content_type], options[:expires],
             format_extension_headers(options[:headers]) + ext_path].join "\n"
          end

          def determine_signing_key options = {}
            options[:signing_key] || options[:private_key] ||
              @service.credentials.signing_key
          end

          def determine_issuer options = {}
            options[:issuer] || options[:client_email] ||
              @service.credentials.issuer
          end

          def post_object options
            options = apply_option_defaults options

            fields = {
              key: ext_path.sub("/", "")
            }

            p = options[:policy] || {}
            fail "Policy must be given in a Hash" unless p.is_a? Hash

            i = determine_issuer options
            s = determine_signing_key options

            fail SignedUrlUnavailable unless i && s

            policy_str = p.to_json
            policy = Base64.strict_encode64(policy_str).delete("\n")

            signature = generate_signature s, policy

            fields[:GoogleAccessId] = i
            fields[:signature] = signature
            fields[:policy] = policy

            Google::Cloud::Storage::PostObject.new GOOGLEAPIS_URL, fields
          end

          def signed_url options
            options = apply_option_defaults options

            i = determine_issuer options
            s = determine_signing_key options

            fail SignedUrlUnavailable unless i && s

            sig = generate_signature s, signature_str(options)
            generate_signed_url i, sig, options[:expires], options[:query]
          end

          def generate_signature signing_key, secret
            unless signing_key.respond_to? :sign
              signing_key = OpenSSL::PKey::RSA.new signing_key
            end
            signature = signing_key.sign OpenSSL::Digest::SHA256.new, secret
            Base64.strict_encode64(signature).delete("\n")
          end

          def generate_signed_url issuer, signed_string, expires, query
            url = "#{ext_url}?GoogleAccessId=#{url_escape issuer}" \
              "&Expires=#{expires}" \
              "&Signature=#{url_escape signed_string}"

            if query
              query.each do |name, value|
                url << "&#{url_escape name}=#{url_escape value}"
              end
            end

            url
          end

          def format_extension_headers headers
            return "" if headers.nil?
            fail "Headers must be given in a Hash" unless headers.is_a? Hash
            flatten = headers.map do |key, value|
              "#{key.to_s.downcase}:#{value.gsub(/\s+/, ' ')}\n"
            end
            flatten.reject! { |h| h.start_with? "x-goog-encryption-key" }
            flatten.sort.join
          end

          def url_escape str
            CGI.escape String str
          end
        end
      end
    end
  end
end
