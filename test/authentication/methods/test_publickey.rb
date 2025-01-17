require 'common'
require 'net/ssh/authentication/methods/publickey'
require 'authentication/methods/common'

module Authentication
  module Methods
    class TestPublickey < NetSSHTest
      include Common

      def test_authenticate_should_return_false_when_no_key_manager_has_been_set
        assert_equal false, subject(key_manager: nil).authenticate("ssh-connection", "jamis")
      end

      def test_authenticate_should_return_false_when_key_manager_has_no_keys
        assert_equal false, subject(keys: []).authenticate("ssh-connection", "jamis")
      end

      def test_authenticate_should_return_false_if_no_keys_can_authenticate
        transport.expect do |t, packet|
          assert_equal USERAUTH_REQUEST, packet.type
          assert verify_userauth_request_packet(packet, keys.first, false)
          t.return(USERAUTH_FAILURE, :string, "hostbased,password")

          t.expect do |t2, packet2|
            assert_equal USERAUTH_REQUEST, packet2.type
            assert verify_userauth_request_packet(packet2, keys.last, false)
            t2.return(USERAUTH_FAILURE, :string, "hostbased,password")
          end
        end

        assert_equal false, subject.authenticate("ssh-connection", "jamis")
      end

      def test_authenticate_should_raise_if_publickey_disallowed
        key_manager.expects(:sign).with(&signature_parameters(keys.first)).returns("sig-one")

        transport.expect do |t, packet|
          assert_equal USERAUTH_REQUEST, packet.type
          assert verify_userauth_request_packet(packet, keys.first, false)
          t.return(USERAUTH_PK_OK, :string, keys.first.ssh_type, :string, Net::SSH::Buffer.from(:key, keys.first))

          t.expect do |t2, packet2|
            assert_equal USERAUTH_REQUEST, packet2.type
            assert verify_userauth_request_packet(packet2, keys.first, true)
            assert_equal "sig-one", packet2.read_string
            t2.return(USERAUTH_FAILURE, :string, "hostbased,password")
          end
        end

        assert_raises Net::SSH::Authentication::DisallowedMethod do
          subject.authenticate("ssh-connection", "jamis")
        end
      end

      def test_authenticate_should_return_false_if_signature_exchange_fails
        key_manager.expects(:sign).with(&signature_parameters(keys.first)).returns("sig-one")
        key_manager.expects(:sign).with(&signature_parameters(keys.last)).returns("sig-two")

        transport.expect do |t, packet|
          assert_equal USERAUTH_REQUEST, packet.type
          assert verify_userauth_request_packet(packet, keys.first, false)
          t.return(USERAUTH_PK_OK, :string, keys.first.ssh_type, :string, Net::SSH::Buffer.from(:key, keys.first))

          t.expect do |t2, packet2|
            assert_equal USERAUTH_REQUEST, packet2.type
            assert verify_userauth_request_packet(packet2, keys.first, true)
            assert_equal "sig-one", packet2.read_string
            t2.return(USERAUTH_FAILURE, :string, "publickey")

            t2.expect do |t3, packet3|
              assert_equal USERAUTH_REQUEST, packet3.type
              assert verify_userauth_request_packet(packet3, keys.last, false)
              t3.return(USERAUTH_PK_OK, :string, keys.last.ssh_type, :string, Net::SSH::Buffer.from(:key, keys.last))

              t3.expect do |t4, packet4|
                assert_equal USERAUTH_REQUEST, packet4.type
                assert verify_userauth_request_packet(packet4, keys.last, true)
                assert_equal "sig-two", packet4.read_string
                t4.return(USERAUTH_FAILURE, :string, "publickey")
              end
            end
          end
        end

        assert !subject.authenticate("ssh-connection", "jamis")
      end

      def test_authenticate_should_return_true_if_any_key_can_authenticate
        key_manager.expects(:sign).with(&signature_parameters(keys.first)).returns("sig-one")

        transport.expect do |t, packet|
          assert_equal USERAUTH_REQUEST, packet.type
          assert verify_userauth_request_packet(packet, keys.first, false)
          t.return(USERAUTH_PK_OK, :string, keys.first.ssh_type, :string, Net::SSH::Buffer.from(:key, keys.first))

          t.expect do |t2, packet2|
            assert_equal USERAUTH_REQUEST, packet2.type
            assert verify_userauth_request_packet(packet2, keys.first, true)
            assert_equal "sig-one", packet2.read_string
            t2.return(USERAUTH_SUCCESS)
          end
        end

        assert subject.authenticate("ssh-connection", "jamis")
      end

      def test_authenticate_rsa_sha2
        key_manager.expects(:sign).with(&signature_parameters_with_alg(keys.first, "rsa-sha2-256")).returns("sig-one")

        transport.expect do |t, packet|
          assert_equal USERAUTH_REQUEST, packet.type
          assert verify_userauth_request_packet(packet, keys.first, false, "rsa-sha2-256")
          t.return(USERAUTH_PK_OK, :string, "rsa-sha2-256", :string, Net::SSH::Buffer.from(:key, keys.first))

          t.expect do |t2, packet2|
            assert_equal USERAUTH_REQUEST, packet2.type
            assert verify_userauth_request_packet(packet2, keys.first, true, "rsa-sha2-256")
            assert_equal "sig-one", packet2.read_string
            t2.return(USERAUTH_SUCCESS)
          end
        end

        assert subject(pubkey_algorithms: %w[rsa-sha2-256]).authenticate("ssh-connection", "jamis")
      end

      def test_authenticate_rsa_sha2_fallback
        key_manager.expects(:sign).with(&signature_parameters(keys.first)).returns("sig-one")

        transport.expect do |t, packet|
          assert_equal USERAUTH_REQUEST, packet.type
          assert verify_userauth_request_packet(packet, keys.first, false, "rsa-sha2-256")
          t.return(USERAUTH_FAILURE, :string, "publickey")

          t.expect do |t2, packet2|
            assert_equal USERAUTH_REQUEST, packet2.type
            assert verify_userauth_request_packet(packet2, keys.first, false)
            t2.return(USERAUTH_PK_OK, :string, keys.first.ssh_type, :string, Net::SSH::Buffer.from(:key, keys.first))

            t2.expect do |t3, packet3|
              assert_equal USERAUTH_REQUEST, packet3.type
              assert verify_userauth_request_packet(packet3, keys.first, true)
              assert_equal "sig-one", packet3.read_string
              t3.return(USERAUTH_SUCCESS)
            end
          end
        end

        assert subject(pubkey_algorithms: %w[rsa-sha2-256 ssh-rsa]).authenticate("ssh-connection", "jamis")
      end

      private

      def signature_parameters(key)
        Proc.new do |given_key, data|
          next false unless given_key.to_blob == key.to_blob

          buffer = Net::SSH::Buffer.new(data)
          buffer.read_string == "abcxyz123"      && # session-id
            buffer.read_byte == USERAUTH_REQUEST && # type
            verify_userauth_request_packet(buffer, key, true)
        end
      end

      def signature_parameters_with_alg(key, alg)
        Proc.new do |given_key, data, given_alg|
          next false unless given_key.to_blob == key.to_blob
          next false unless given_alg == alg

          buffer = Net::SSH::Buffer.new(data)
          buffer.read_string == "abcxyz123"      && # session-id
            buffer.read_byte == USERAUTH_REQUEST && # type
            verify_userauth_request_packet(buffer, key, true, alg)
        end
      end

      def verify_userauth_request_packet(packet, key, has_sig, alg = nil)
        packet.read_string == "jamis" && # user-name
          packet.read_string == "ssh-connection" && # next service
          packet.read_string == "publickey"      && # auth-method
          packet.read_bool   == has_sig          && # whether a signature is appended
          packet.read_string == (alg || key.ssh_type) && # ssh key type
          packet.read_buffer.read_key.to_blob == key.to_blob # key
      end

      @@keys = nil
      def keys
        @@keys ||= [OpenSSL::PKey::RSA.new(512), OpenSSL::PKey::DSA.new(512)]
      end

      def key_manager(options = {})
        @key_manager ||= begin
          manager = stub("key_manager")
          manager.stubs(:each_identity).multiple_yields(*(options[:keys] || keys))
          manager
        end
      end

      def subject(options = {})
        options[:key_manager] = key_manager(options) unless options.key?(:key_manager)
        options[:pubkey_algorithms] = %w[ssh-rsa] unless options.key?(:pubkey_algorithms)
        @subject ||= Net::SSH::Authentication::Methods::Publickey.new(session(options), options)
      end
    end
  end
end
