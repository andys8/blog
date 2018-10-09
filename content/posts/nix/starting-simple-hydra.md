---
title: Your First Hydra
date: 2018-10-09
authors: schalmers
project: infra
---

### Intro / Goal

Hydra is a bit of a monster and there isn't much documentation on how to start, this post aims to
fix at least a bit of the latter. I'm going to walk you through setting up a local Hydra instance on
a virtual machine. This will be a stand alone Hydra instance, so no build slaves.

### Assumptions / Requirements

This tutorial was tested on a machine running `NixOS`, it should work on any machine that has
`Nix`, `NixPkgs`, and `NixOps`. I assume a level of `Nix` knowledge whereby you are comfortable
writing your own `Nix` expressions and debugging failures. This is still a bit of a bleeding edge
part of the `Nix` ecosystem so things don't always go according to plan.

You will need `nixops` installed.

### Simple NixOps

To manage the running of our Hydra machine, we're going to leverage `NixOps` to create, start, run,
and update our virtual machine. This lets us have a declarative defintion of our build machine, as
well as a consistent interface for managing the machine(s).

We're going to create two Nix expressions:

1.  The virtual machine environment.
2.  The configuration of the Hydra machine.

### The virtual machine

We're going to create the definition for our Hydra machine. This will be a 'headless' VirtualBox
machine, with some settings to keep the overall size of the machine down and lock down access.

We create a `Nix` `attrset` that contains a function that defines our machine, this function is
attached to a name that will be used as the `<HOSTNAME>` of the machine within `NixOps`. We use the
name `my-hydra` here, and we'll need to use that name again when we write our machine configuration.

    {
      my-hydra =
        { config, pkgs, ... }: {

`NixOps` lets you choose your deployment environment, this example uses VirtualBox as we're creating
a trivial machine. The [NixOps Manual](https://nixos.org/nixops/manual/) has much more information about supported target environments
and their respective options and requirements.

    deployment.targetEnv = "virtualbox"; # for libvrtd/QEMU use "libvrtd"

Provide some settings for our VirtualBox machine. The machine will need a fair chunk of memory, as
evaluating the `nixpkgs` tree to build the dependencies can be expensive. And as with any CI system,
you need to make sure your target has sufficient resources to actually run the required builds.

Our machine doesn't require a GUI so we enable `headless` mode. Note that these are `virtualbox`
specific settings, each target will have their own collection of options, check the manual for more
information.

    deployment.virtualbox.memorySize = 4096;
    deployment.virtualbox.vcpu = 2;
    deployment.virtualbox.headless = true;

We'll also turn off the manual from appearing on the machine, this saves a bit more space. We enable
a time daemon, `ntp`. Then set the access controls for SSH, disallowing SFTP and password based
authentication.

    services.nixosManual.showManual         = false;
    services.ntp.enable                     = false;
    services.openssh.allowSFTP              = false;
    services.openssh.passwordAuthentication = false;

Provide some settings for the users on the machine. The `mutableUsers` option means that every time
the system is deployed the user information will be completely replaced by the static definition
from this file. The next setting for `keyFiles` will copy the listed SSH key files to the target
machine. 

In this example we're just going to copy across an RSA public key from a pair. This allows us to use
`nixops ssh -d <deployment-name> <machine-name>` to access the machine via SSH.

          users = {
            mutableUsers = false;
            users.root.openssh.authorizedKeys.keyFiles = [ ~/.ssh/id_rsa.pub ];
          };
        };
    }

We put all of the above in a file named `simple_hydra_vbox.nix`, this will form part of the input
for our `nixops` command later on. This is the machine, but that isn't much good without a
definition for what will run on the machine itself. Next we will define the Hydra machine itself,
with some caveats because we're running on a local, virtualised machine.

### A basic Hydra

What follows is a `NixOps` expression for a stand-alone Hydra build machine. It is enough to start
your own Hydra instance with a binary cache. There are sections which are required for running this
machine in a virtual machine, but we'll cover those as we go. This machine will not define any build
slaves, and it will build and cache everything locally.

As before, we write a `nix` expression that is a function that produces our machine configuration.
Note that the name we assign matches the virualisation configuration. This must match otherwise
there will be an error from `NixOps`. This attribute is also used as the machine hostname, so any
where you see `<HOSTNAME>` in the configuration, replace that with this name.

    {
      my-hydra = 
        { config, pkgs, ...}: {

As Hydra is able to send emails for various events, so our machine will need some sort of email
capability. Because we're building a `NixOS` machine we're able to enable the `postfix` service like so:

    services.postfix = {
        enable = true;
        setSendmail = true;
    };

The build queues and parts of the jobset configuration are all stored in a postgres database, so we
need to enable it and also provide a mapping from `NixOS` users to `PostgreSQL` users. Otherwise
Hydra won't be able to access the database!

    services.postgresql = {
        enable = true;
        package = pkgs.postgresql;
        identMap =
          ''
            hydra-users hydra hydra
            hydra-users hydra-queue-runner hydra
            hydra-users hydra-www hydra
            hydra-users root postgres
            hydra-users postgres postgres
          '';
    };


- TODO Would need to add postfix port to this so email works??
- TODO Only required when running in a local virtual machine??
This next setting is to tell `NixOS` to open the TCP port we're going to use for accessing the web
interface for Hydra.

```
    networking.firewall.allowedTCPPorts = [ config.services.hydra.port ];
```

Now we get onto the meaty part of creating our Hydra configuration, as we're using `NixOS` we enable
the `hydra` service and provide our required settings.

    services.hydra = {
        enable = true;
        useSubstitutes = true;
        hydraURL = "https://hydra.example.org";
        notificationSender = "hydra@example.org";

The `hydraURL` setting is the page for the Hydra web interface, it is also used in emails as the
root path for any links back to this Hydra system. The `notificationSender` setting is the <span class="underline">from</span>
address of emails from this Hydra system.

The `useSubstitutes` setting is a bit more complicated&#x2026; It's best to refer to the manual for this one:

> Whether to use binary caches for downloading store paths. Note that binary substitutions trigger (a
> potentially large number of) additional HTTP requests that slow down the queue monitor thread
> significantly. Also, this Hydra instance will serve those downloaded store paths to its users with
> its own signature attached as if it had built them itself, so don't enable this feature unless your
> active binary caches are absolute trustworthy.
> 
> &#x2013; From <https://nixos.org/nixos/options.html#services.hydra.usesubstitutes>

With this enabled you will reap the benefits of cached build dependencies and spare precious cycles
by not constantly rebuilding things that don't need to be. The trade-off is a high number of HTTP
requests that may affect the running of the Hydra system. Depending on how active your build queue
is, this may be a cause for concern.

The following setting is important and required (even though it is empty) because we're building a
stand-alone Hydra instance. We have to explictly tell Hydra that there are no additional build
machines defined in files.

Without this setting, Hydra will ignore our `machine` definition and the Hydra instance will be not
function as the expected build machine configuration does not match reality.

    buildMachinesFiles = [];

We provide some `extraConfig` to tell Hydra where to place the binary cache and where we're going to
put the secret key.

        extraConfig = ''
          store_uri = file:///var/lib/hydra/cache?secret-key=/etc/nix/<HOSTNAME>/secret
          binary_cache_secret_key_file = /etc/nix/<HOSTNAME>/secret
          binary_cache_dir = /var/lib/hydra/cache
        '';
    };

See here (<https://nixos.org/nixos/options.html#services.hydra>) for a full list of the options
available for the Hydra service in `NixOS`.

The following is optional, but here for example purposes about using `nginx` to serve the Hydra web
interface. This Hydra instance was running locally in a VM so this wasn't needed. The full scope of
Nginx configuration and what is available via `NixOS` is well beyond this post.

    services.nginx = {
      enable = true;
      recommendedProxySettings = true;
      virtualHosts."hydra.example.org" = {
        forceSSL = true;
        enableACME = true;
        locations."/".proxyPass = "http://localhost:3000";
      };
    };

Hydra requires manual steps beyond the configuration of the `NixOS` service. This is only a one time
requirement however. We leverage a `systemd` service to manage the dependencies of when to trigger
this final state. This provides some additional guarantees that the final configuration will run
<span class="underline">after</span> Hydra is installed and running.

The initial options are for setting up the `systemd` settings.

    systemd.services.hydra-manual-setup = {
      description = "Create Admin User for Hydra";
      serviceConfig.Type = "oneshot";
      serviceConfig.RemainAfterExit = true;
      wantedBy = [ "multi-user.target" ];
      requires = [ "hydra-init.service" ];
      after = [ "hydra-init.service" ];
      environment = builtins.removeAttrs (config.systemd.services.hydra-init.environment) ["PATH"];

This is the script that is run by the `systemd` service, we predicate its execution on the existence
of a `.setup-is-complete` file.

      script = ''
        if [ ! -e ~hydra/.setup-is-complete ]; then
          # create signing keys
          /run/current-system/sw/bin/install -d -m 551 /etc/nix/<HOSTNAME>
          /run/current-system/sw/bin/nix-store --generate-binary-cache-key <HOSTNAME> /etc/nix/<HOSTNAME>/secret /etc/nix/<HOSTNAME>/public
          /run/current-system/sw/bin/chown -R hydra:hydra /etc/nix/<HOSTNAME>
          /run/current-system/sw/bin/chmod 440 /etc/nix/<HOSTNAME>/secret
          /run/current-system/sw/bin/chmod 444 /etc/nix/<HOSTNAME>/public
          # create cache
          /run/current-system/sw/bin/install -d -m 755 /var/lib/hydra/cache
          /run/current-system/sw/bin/chown -R hydra-queue-runner:hydra /var/lib/hydra/cache
          # done
          touch ~hydra/.setup-is-complete
        fi
      '';
    };

As we indicated in the `extraConfig` section of Hydra, we're going to have a binary store on this
machine. This is where we generate the secret keys and create the cache itself.

Next we set some explict `nix` settings to schedule the garbage collection of the store, and also
the automatically optimise the store. Which means that `nix` will remove duplicate files from the
store, replacing them with hard links to a single copy.

    nix.gc = {
      automatic = true;
      dates = "15 3 * * *";
    };
    
    nix.autoOptimiseStore = true;

This tells `NixOS` which users are allowed to interact with the `nix` store in a more privileged
fashion, such as adding binary caches.

    nix.trustedUsers = ["hydra" "hydra-evaluator" "hydra-queue-runner"];

Finally we setup the build machine so that Hydra has a machine to orchestrate for the builds. In
this example we're building locally, so we set our `hostName` to "localhost". Use the `systems`
setting to indicate the systems or architectures that we able to build for, `maxJobs` to
unsurprisingly set the maximum number of build processes.

Finally you declare the "Features" that this build machine supports. If a derivation is submitted
that requires features that are not supported on a given build machine then it will not be built.

        nix.buildMachines = [
          {
            hostName = "localhost";
            systems = [ "x86_64-linux" "i686-linux" ];
            maxJobs = 6;
            # for building VirtualBox VMs as build artifacts, you might need other 
            # features depending on what you are doing
            supportedFeatures = [];
          }
        ];
      };
    }

Place all of that configuration in a file called `simple_hydra.nix` and we're ready to start powering up.

#### Powering up

Now to tell `NixOps` to create and prepare our Hydra instance.

    $ cd <path to 'simple_hydra' nix files>

##### Create the virtual machine within NixOps

Before you can initiate the deployment of your machine, you need to make `NixOps` aware of it:

    $ nixops create ./simple_hydra.nix ./simple_hydra_vbox.nix -d simple_hydra
    created deployment ‘5537e9ba-cabf-11e8-80d0-d481d7517abf’ ### This hash will differ for your machine
    5537e9ba-cabf-11e8-80d0-d481d7517abf

If that completes without error, you should the be able to issue the following command to `NixOps`:

    $ nixops info -d simple_hydra
    Network name: simple_hydra
    Network UUID: 5537e9ba-cabf-11e8-80d0-d481d7517abf
    Network description: Unnamed NixOps network
    Nix expressions: /path/to/simple_hydra.nix /path/to/simple_hydra_vbox.nix
    
    +----------|---------------|------------|-------------|------------+
    | Name     |     Status    | Type       | Resource Id | IP address |
    +----------|---------------|------------|-------------|------------+
    | my-hydra | Missing / New | virtualbox |             |            |
    +----------|---------------|------------|-------------|------------+

The `info` command for `nixops` provides feedback about the status of the machine(s) you have
deployed, their IP addresses, and other things. This information is stored local to the machine that
issued this `nixops` command, it is not shared between different deployment machines. So even if you
deploy to AWS using `nixops`, someone else that has the same `nix` expressions for your machines
will not have any knowledge of their deployment status.

##### Trigger deployment of the virtual machine

We can now tell `nixops` to deploy the configuration we've written to the virtual machines, this
part can take a while. Once you issue the following command you might like to get up and stretch, or
go and refresh the cup of your favourite beverage.

The `--force-reboot` is required to ensure the Hydra services are started correctly. If you do not
include it then the deployment will report an error, but will have actually completed successfully.
However you would still need to restart the machine in order to continue.

    $ nixops deploy -d simple_hydra --force-reboot

`NixOps` will then set about the task of creating the virtual machine, initialising all the disks
and network settings etc. Then create the configuration prior to copying to the newly minted
machine. After which, barring any errors you should see the following text:

    my-hydra> waiting for the machine to finish rebooting...[down]......................[up]
    my-hydra> activation finished successfully
    simple_hydra> deployment finished successfully

Once the machine is deployed, you can check its status using `$ nixops info -d simple_hydra`.

    Network name: simple_hydra
    Network UUID: c58245b3-cac2-11e8-9346-d481d7517abf
    Network description: Unnamed NixOps network
    Nix expressions: /path/to/simple_hydra.nix /path/to/simple_hydra_vbox.nix
    
    +----------|-----------------|------------|------------------------------------------------------|----------------+
    | Name     |      Status     | Type       | Resource Id                                          | IP address     |
    +----------|-----------------|------------|------------------------------------------------------|----------------+
    | my-hydra | Up / Up-to-date | virtualbox | nixops-c58245b3-cac2-11e8-9346-d481d7517abf-my-hydra | 192.168.56.101 |
    +----------|-----------------|------------|------------------------------------------------------|----------------+

This deployment is aware of the two nix expressions that were used to create it, if those files
disappear then you not be able to destroy or update the machine via `NixOps`. The other side is that
if you change those files the you only have to issue the `deploy` command again and `NixOps` will
take care of updating the machine to the new configuration.

If things have gone according to plan then you should be able to point a browser tab at the Hydra
web UI. The address will be the default Hydra port of `3000` at the IP address listed in the output
from the `nixops info -d simple_hydra` command. Using the above output as an example the address for
the Hydra page is: `http://192.168.56.101:3000`.

We're ready to start adding some `jobsets` to our Hydra instance, but there is a bit of a problem as
we don't have any user accounts!

### Add the Hydra admin user

To add an admin user to Hydra, we use the `hydra-create-user` program that is included with Hydra.
An example of how to create an admin user is:

    $ hydra-create-user admin \
        --full-name "Bobby Admin" \
        --email-address "bobby@example.org" \
        --password TOTALLYSECURE \
        --role admin

This program is on the Hydra machine itself so we need to SSH in, or send the instruction over SSH.
The `nixops ssh` command lets you do both: To run the command on the machine by connecting first:

    $ nixops ssh -d simple_hydra my-hydra
    creating new user `admin`

This will put you on the machine at a prompt as `root` on the `my-hydra` machine on the
`simple_hydra` deployment. You can then run the create user command.

Alternatively you can simply send the single instruction over SSH:

    $ nixops ssh -d simple_hydra my-hydra '<create-user-command>'
    creating new user `admin`

Putting the command in quotes after the `nixops ssh` command will send a single instruction over
SSH, printing any output.

