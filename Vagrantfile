Vagrant.configure 2 do |config|

  config.vm.box = 'ubuntu/xenial64'
  config.vm.network 'forwarded_port', guest: 4000, host: 4000

  config.vm.provision :shell,
    :inline => 'sudo apt-get update && sudo apt-get -y install build-essential git ruby2.3 ruby-dev zlib1g-dev && sudo gem install bundler'
end
