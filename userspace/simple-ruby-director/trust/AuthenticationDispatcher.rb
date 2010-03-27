require 'monitor.rb'

class NegotiatedSession
    # Public key of the node requesting the session
    attr_reader :client
    # Public key of the node being requested
    attr_reader :server
    # Handshake key generated by client
    attr_accessor :clientChallenge
    # Handshake key generated by server
    attr_accessor :serverChallenge
    # This is a final challenge used for authentication on server connect. During the handshake it is sent only in an encrypted form
    attr_accessor :proof
    # This attribute is set to true when the second party identity is verified (server & client set this at their side in different times)
    # Initially, the attribute is nil. If set to false, it means the identity verification has failed
    attr_reader :confirmed
    # Initially it is a time when the request was send, in the end it is a time when the confirmation was set
    # Timestamp is used for timouting and deletion of idle negotiations (or expiration of confirmed negotiations)
    # TODO: Implement this auto-deletetion
    attr_accessor :timestamp
    
    def initialize(clientKey, serverKey)
        @client = clientKey
        @server = serverKey
        @confirmed = nil
        @timestamp = Time.now()
        # Monitor object to control waiting
        @monitor = Monitor.new
	@condition = @monitor.new_cond
    end    
    
    def confirmed=(value)
        # Update timestamp on confirmation
        @timestamp = Time.now()        
        @confirmed = value
	@monitor.synchronize {
        	@condition.broadcast()
	}
    end
    
    # Waits till confirmation is either false or true
    def waitForConfirmationState(timeoutSeconds)
        # TODO: There is a chance we'll wait for full timeout without getting signal. Better locking would be nice
	@monitor.synchronize {
        	@condition.wait(timeoutSeconds) if @confirmed == nil
	}        
    end
end

class AuthenticationDispatcher
    attr_reader :localIdentity
    attr_reader :interconnection    

    def initialize(localIdentity, interconnection)
        @localIdentity = localIdentity
        @interconnection = interconnection        
        
        # Set of session negotiations initiated by this node
        # Key: Public key of peer server
        # Value: Associated NegotiatedSession object
        @clientNegotiations = {}

        # Set of session negotiations initiated by other node, requesting this node to be a server
        # Key: Public key of peer client
        # Value: Associated NegotiatedSession object        
        @serverNegotiations = {}

	# Kept on server side. Maps proof to negotiation (assumes proof are unique)
	# TODO: Implement prevention against brute-force attack on proofs!
        # TODO: Timeouts of these records
	@authenticatedNegotiations = {} 

        @interconnection.addReceiveHandler(STSInitialRequest, STSInitialRequestHandler.new(@serverNegotiations, @interconnection, @localIdentity, @authenticatedNegotiations)) if ( interconnection )
        @interconnection.addReceiveHandler(STSServerChallenge, STSServerChallengeHandler.new(@clientNegotiations, @interconnection, @localIdentity)) if ( interconnection )
        @interconnection.addReceiveHandler(STSFinalize, STSFinalizeHandler.new(@serverNegotiations)) if ( interconnection )
    end
    
    # This is called at the server as a callback when a new session is being created in kernel
    # It is assumed the session was prepared by the client by preceding call to prepareSession(..)
    # The request should carry a proof of identity exchanged during the handshake
    def checkNewSessionRequest(proof)
        # No such a session negotiatied?
        # TODO: Check timouts via timestamps!
        return false if ( !@authenticatedNegotiations[proof] )
	remoteKey = @authenticatedNegotiations[proof].client
	@authenticatedNegotiations[proof] = nil # Remote the record
        # There is a chance we got here before getting the client confirmation message => give it a chance to arrive
        @serverNegotiations[remoteKey].waitForConfirmationState(10)
        # Fail if the identity was not verified
        return false if !@serverNegotiations[remoteKey].confirmed
	# We know the proof is matching as we got neg session by the proof
        return true
    end
    
    # Prepares session at remote node (requesting side is the client)
    # Executed on client
    # Returns proof to be presented on "connect", if the session negotiation was completed, nil otherwise
    def prepareSession(remoteKey)
	$log.debug("Trying to negotiate a new session")
        # TODO: Here we should use a real large number not this bullshit!
        xValue = rand(99999999999999999)
        initialMessage = STSInitialRequest.new(@localIdentity.publicKey, xValue)
        @clientNegotiations[remoteKey] = NegotiatedSession.new(@localIdentity.publicKey, remoteKey)        
        @clientNegotiations[remoteKey].clientChallenge = xValue
        @interconnection.dispatch(remoteKey, initialMessage)        
        # Blocking wait for confirmation state (TODO: Better would be to make some callback action to handle this asynchronously so that we do not need to block here!)
        @clientNegotiations[remoteKey].waitForConfirmationState(10)
        $log.debug("Negotiation finished. Confirmed = #{@clientNegotiations[remoteKey].confirmed}")

	return nil if ( !@clientNegotiations[remoteKey].confirmed )

        return @clientNegotiations[remoteKey].proof
    end
    
    # Listens on initial session requests and issues server challenge key + signature
    # Executed on server
    class STSInitialRequestHandler
	def initialize(serverNegotiations, interconnection, localIdentity, authenticatedNegotiations)
		@serverNegotiations = serverNegotiations
		@interconnection = interconnection
		@localIdentity = localIdentity
		@authenticatedNegotiations = authenticatedNegotiations
	end

        def handle(message)            
            # Server received an auth challenge => Prepare yValue and challenge the client
            xValue = message.challenge
            # TODO: Here we should use a real large number not this bullshit!
            yValue = rand(99999999999999999)
	    proof = rand(99999999999999999)
	    $log.info("Initial authentication request received. X: #{xValue} Y: #{yValue}")
            # TODO and use a real concat
            valueToSign = yValue.to_s + xValue.to_s
            signature = @localIdentity.sign(valueToSign)
	    encryptedProof = message.publicKey.public_encrypt(proof.to_s)
            serverChallengeMessage = STSServerChallenge.new(@localIdentity.publicKey, yValue, signature, encryptedProof)
            @serverNegotiations[message.publicKey] = NegotiatedSession.new(message.publicKey, @localIdentity.publicKey)
            @serverNegotiations[message.publicKey].clientChallenge = xValue
            @serverNegotiations[message.publicKey].serverChallenge = yValue
	    @serverNegotiations[message.publicKey].proof = proof
	    # TODO: Check for proof collisions?
            @authenticatedNegotiations[proof.to_s] = @serverNegotiations[message.publicKey]
            @interconnection.dispatch(message.publicKey, serverChallengeMessage, DeliveryOptions::ACK_1_MIN)
        end
    end

    # Executed on client 
    class STSServerChallengeHandler
	def initialize(clientNegotiations, interconnection, localIdentity)
		@clientNegotiations = clientNegotiations
		@interconnection = interconnection
		@localIdentity = localIdentity
	end

        def handle(message)            
	    $log.info("Server challenge received")
            # Already expired (or other bullshit arrived?)
            return if !@clientNegotiations[message.publicKey]
            
            yValue = message.challenge
            xValue = @clientNegotiations[message.publicKey].clientChallenge
            valueToSign = yValue.to_s + xValue.to_s            
            if !message.publicKey.verifySignature(message.signature, valueToSign)
                $log.debug("Server signature verification failed for public key peer #{message.publicKey.undecorated_to_s}")
                # TODO: Delete record here or let it up-to autodeletion
                @clientNegotiations[message.publicKey].confirmed = false
                return
            end

	    @clientNegotiations[message.publicKey].proof = @localIdentity.decrypt(message.proof)
            
            $log.debug("Server identity confirmed ")
            
            valueToSign = xValue.to_s + yValue.to_s
            signature = @localIdentity.sign(valueToSign)
            finalMessage = STSFinalize.new(@localIdentity.publicKey, signature)
	    @interconnection.dispatch(message.publicKey, finalMessage)

            @clientNegotiations[message.publicKey].confirmed = true            
        end
    end
    
    # Executed on server
    class STSFinalizeHandler
	def initialize(serverNegotiations)
		@serverNegotiations = serverNegotiations		
	end

        def handle(message)            
            # Already expired (or other bullshit arrived?)
            return if !@serverNegotiations[message.publicKey]
            
            yValue = @serverNegotiations[message.publicKey].serverChallenge
            xValue = @serverNegotiations[message.publicKey].clientChallenge
            valueToSign = xValue.to_s + yValue.to_s
            
            if !message.publicKey.verifySignature(message.signature, valueToSign)
                $log.debug("Client signature verification failed for public key peer #{message.publicKey.undecorated_to_s}")
                # TODO: Delete record here or let it up-to autodeletion
                @serverNegotiations[message.publicKey].confirmed = false
                return
            end            
            	 
            $log.debug("Client identity confirmed. Registering negotiated proof #{@serverNegotiations[message.publicKey].proof}")
            @serverNegotiations[message.publicKey].confirmed = true
        end
    end
    
end