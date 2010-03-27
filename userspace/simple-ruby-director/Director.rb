require 'FilesystemConnector'
require 'FilesystemNodeBuilder'
require 'MockNetlinkConnector'
require 'NetlinkConnector'
require 'NodeRepository'
require 'NodeInfoProvider'
require 'NodeInfoConsumer'
require 'Manager'
require 'MembershipManager'
require 'ManagerMonitor'
require 'InformationDistributionStrategy'
require 'LoadBalancer'
require 'RandomBalancingStrategy'
require 'CpuLoadBalancingStrategy'
require 'QuantityLoadBalancingStrategy'
require 'SignificanceTracingFilter'
require 'ExecDumper'
require 'ExecutionTimeTracer'
require 'TaskRepository'
require 'logger'
require 'trust/Identity.rb'
require 'trust/TrustManagement.rb'
require 'cli/CliServer.rb'
require 'trust/TrustCliHandlers.rb'
require 'trust/TrustCliParsers.rb'
require 'trust/CertificatesDistributionStrategy.rb'

require 'Interconnection.rb'

require 'TestMakeAcceptLimiter'
#require "xray/thread_dump_signal_handler"


#This is the main class that is running on the Clondike cluster node
#It controls both Core node and Detached nodes
#This class should be started AFTER core and/or detached node kernel managers are started!
class Director	
        CONF_DIR = "conf"
    
	attr_reader :nodeRepository	
	
	def initialize
                acceptLimiter = TestMakeAcceptLimiter.new();

		@interconnection = Interconnection.new(InterconnectionUDPMessageDispatcher.new(), CONF_DIR)
		initializeTrust()

		#idResolver = IpBasedNodeIdResolver.new
		idResolver = PublicKeyNodeIdResolver.new(@trustManagement)
                @nodeInfoProvider = NodeInfoProvider.new(idResolver)
                currentNode = CurrentNode.createCurrentNode(@nodeInfoProvider)

		$log.info("Starting director on node with id #{currentNode.id}")    

		@nodeRepository = NodeRepository.new(currentNode)                                
		@filesystemConnector = FilesystemConnector.new
                @membershipManager = MembershipManager.new(@filesystemConnector, @nodeRepository, @trustManagement)
		@managerMonitor = ManagerMonitor.new(@interconnection, @membershipManager, @nodeRepository)
                @taskRepository = TaskRepository.new(@nodeRepository, @membershipManager)
                #balancingStrategy = RandomBalancingStrategy.new(@nodeRepository, @membershipManager)
                #balancingStrategy = CpuLoadBalancingStrategy.new(@nodeRepository, @membershipManager)
                balancingStrategy = QuantityLoadBalancingStrategy.new(@nodeRepository, @membershipManager)
                @loadBalancer = LoadBalancer.new(balancingStrategy)                
                @nodeInfoConsumer = NodeInfoConsumer.new(@nodeRepository, idResolver.getCurrentId)
                @nodeInfoConsumer.registerNewNodeListener(@membershipManager)
                @informationDistributionStrategy = InformationDistributionStrategy.new(@nodeInfoProvider, @nodeInfoConsumer)
                @nodeInfoProvider.addListener(SignificanceTracingFilter.new(@informationDistributionStrategy))
                @nodeInfoProvider.addListener(currentNode)                                
                @nodeInfoProvider.addLimiter(acceptLimiter)
                
                #@taskRepository.registerListener(ExecutionTimeTracer.new)
                @taskRepository.registerListener(balancingStrategy)
                @taskRepository.registerListener(acceptLimiter)
                @loadBalancer.registerMigrationListener(@taskRepository)
                                
                            
                initializeCliServer()
	end

	# Starts director processing
	def start
                $log.debug @nodeInfoProvider.getCurrentInfoWithId.to_s
                $log.debug @nodeInfoProvider.getCurrentStaticInfo.to_s            

		#Start kernel listening thread		
                begin                  
                    @netlinkConnector = NetlinkConnector.new(@membershipManager)
                rescue
                    $log.warn "Creating mock netlink connector as a real connector cannot be created!"
                    @netlinkConnector = MockNetlinkConnector.new(@membershipManager)                  
                end
                @netlinkConnector.pushNpmHandlers(@taskRepository)
                @netlinkConnector.pushNpmHandlers(ExecDumper.new())
                @netlinkConnector.pushNpmHandlers(@loadBalancer)
                @netlinkConnector.pushExitHandler(@taskRepository)
		@netlinkConnector.pushUserMessageHandler(@interconnection)
		@netlinkConnector.startProcessingThread                                
                
                #Start notification thread
                @nodeInfoProvider.startNotifyThread
                
                @informationDistributionStrategy.start  
                @interconnection.start(@trustManagement, @netlinkConnector)
		@managerMonitor.start()
	end

	# Waits, till director and all its threads terminates
	def waitForFinished
		@netlinkConnector.waitForProcessingThread
                @nodeInfoProvider.waitForNotifyThread
                @informationDistributionStrategy.waitForFinished
	end
        
private
        def initializeTrust
	      distributionStrategy = BroadcastCertificateDistributionStrategy.new(@interconnection)	
              @identity = Identity.loadIfExists(CONF_DIR, distributionStrategy)
              if ( !@identity )
                  @identity = Identity.create(CONF_DIR, distributionStrategy)      
                  @identity.save()                                    
              end
              @trustManagement = TrustManagement.new(@identity, @interconnection)
        end
        
        def initializeCliServer
            parser = CliParser.new            
            registerAllTrustParsers(parser)
            interpreter = CliInterpreter.new(parser)
            registerAllTrustHandler(@trustManagement, interpreter)
            server = CliServer.new(interpreter, 4223)
            server.start            
        end
end

$log = Logger.new(STDOUT)
$log.level = Logger::DEBUG;
    
director = Director.new
director.start
director.waitForFinished