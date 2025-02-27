# @summary Installs and configures kubelet
class k8s::node::kubelet (
  K8s::Ensure $ensure = $k8s::node::ensure,

  Stdlib::HTTPUrl $master = $k8s::node::master,

  Hash[String, Data] $config        = {},
  Hash[String, Data] $arguments     = {},
  String $runtime                   = $k8s::container_manager,
  String $runtime_service           = $k8s::container_runtime_service,
  String[1] $puppetdb_discovery_tag = $k8s::node::puppetdb_discovery_tag,

  K8s::Node_auth $auth       = $k8s::node::node_auth,
  Boolean $rotate_server_tls = $auth == 'bootstrap',
  Boolean $manage_firewall   = $k8s::node::manage_firewall,
  Boolean $support_dualstack = $k8s::cluster_cidr =~ Array[Data, 2],

  Stdlib::Unixpath $cert_path  = $k8s::node::cert_path,
  Stdlib::Unixpath $kubeconfig = '/srv/kubernetes/kubelet.kubeconf',

  # For cert auth
  Optional[Stdlib::Unixpath] $ca_cert = $k8s::node::ca_cert,
  Optional[Stdlib::Unixpath] $cert    = $k8s::node::node_cert,
  Optional[Stdlib::Unixpath] $key     = $k8s::node::node_key,

  # For token and bootstrap auth
  Optional[String[1]] $token = $k8s::node::node_token,
) {
  k8s::binary { 'kubelet':
    ensure => $ensure,
    notify => Service['kubelet'],
  }

  if $auth == 'bootstrap' {
    $_bootstrap_kubeconfig = '/srv/kubernetes/bootstrap-kubelet.kubeconf'
  } else {
    $_bootstrap_kubeconfig = undef
  }

  case $auth {
    'bootstrap': {
      $_ca_cert = pick($ca_cert, '/var/lib/kubelet/pki/ca.pem')
      ensure_packages(['jq'])
      if !defined(K8s::Binary['kubectl']) {
        k8s::binary { 'kubectl':
          ensure => $ensure,
        }
      }
      exec { 'Remove broken CA':
        path    => ['/usr/local/bin','/usr/bin','/bin'],
        command => "rm '${_ca_cert}'",
        onlyif  => "stat '${_ca_cert}' | grep 'Size: 0'",
      }
      ~> exec { 'Retrieve K8s CA':
        path    => ['/usr/local/bin','/usr/bin','/bin'],
        command => "kubectl --server='${master}' --username=anonymous --insecure-skip-tls-verify=true \
          get --raw /api/v1/namespaces/kube-system/configmaps/cluster-info | jq .data.ca -r > '${_ca_cert}'",
        creates => $_ca_cert,
        require => [
          K8s::Binary['kubectl'],
          Package['jq'],
        ],
      }
      -> kubeconfig { $_bootstrap_kubeconfig:
        ensure          => $ensure,
        owner           => 'kube',
        group           => 'kube',
        server          => $master,
        current_context => 'default',
        token           => $token,

        ca_cert         => $_ca_cert,

        notify          => Service['kubelet'],
      }
      File <| title == $_ca_cert |> -> Kubeconfig[$_bootstrap_kubeconfig]
      $_authentication_hash = {
        'authentication'     => {
          'x509' => {
            'clientCAFile' => $_ca_cert,
          },
        },
      }
    }
    'token': {
      kubeconfig { $kubeconfig:
        ensure          => $ensure,
        owner           => 'kube',
        group           => 'kube',
        server          => $master,
        current_context => 'default',
        token           => $token,
        notify          => Service['kubelet'],
      }
      $_authentication_hash = {}
    }
    'cert': {
      kubeconfig { $kubeconfig:
        ensure          => $ensure,
        owner           => 'kube',
        group           => 'kube',
        server          => $master,
        current_context => 'default',

        ca_cert         => $ca_cert,
        client_cert     => $cert,
        client_key      => $key,
        notify          => Service['kubelet'],
      }
      $_authentication_hash = {
        'authentication'     => {
          'x509' => {
            'clientCAFile' => $ca_cert,
          },
        },
      }
    }
    default: {
    }
  }

  $config_hash = {
    'apiVersion'         => 'kubelet.config.k8s.io/v1beta1',
    'kind'               => 'KubeletConfiguration',

    'staticPodPath'      => '/etc/kubernetes/manifests',
    'tlsCertFile'        => $cert,
    'tlsPrivateKeyFile'  => $key,
    'rotateCertificates' => $auth == 'bootstrap',
    'serverTLSBootstrap' => $rotate_server_tls,
    'clusterDomain'      => $k8s::cluster_domain,
    'clusterDNS'         => [
      $k8s::dns_service_address,
    ].flatten,
    'cgroupDriver'       => 'systemd',
  } + $_authentication_hash

  file { '/etc/modules-load.d/k8s':
    ensure  => $ensure,
    content => file('k8s/etc/modules-load.d/k8s'),
  }
  exec {
    default:
      path        => ['/bin', '/sbin', '/usr/bin'],
      refreshonly => true,
      subscribe   => File['/etc/modules-load.d/k8s'];

    'modprobe overlay':
      unless => 'lsmod | grep overlay';

    'modprobe br_netfilter':
      unless => 'lsmod | grep overlay';
  }

  file { '/etc/sysctl.d/99-k8s.conf':
    ensure  => $ensure,
    content => file('k8s/etc/sysctl.d/99-k8s.conf'),
  }
  exec { 'sysctl --system':
    path        => ['/sbin', '/usr/sbin'],
    refreshonly => true,
    subscribe   => File['/etc/sysctl.d/99-k8s.conf'],
  }

  file { '/etc/kubernetes/kubelet.conf':
    ensure  => $ensure,
    content => to_yaml($config_hash + $config),
    owner   => 'kube',
    group   => 'kube',
    notify  => Service['kubelet'],
  }

  if $runtime == 'crio' {
    $_runtime_endpoint = 'unix:///var/run/crio/crio.sock'
    $_runtime = 'remote'
  } else {
    $_runtime_endpoint = undef
    $_runtime = undef
  }

  if $support_dualstack and fact('networking.ip') and fact('networking.ip6') {
    $_node_ip = [fact('networking.ip'), fact('networking.ip6')]
  } else {
    $_node_ip = undef
  }

  $_args = k8s::format_arguments({
      config                     => '/etc/kubernetes/kubelet.conf',
      kubeconfig                 => $kubeconfig,
      bootstrap_kubeconfig       => $_bootstrap_kubeconfig,
      cert_dir                   => $cert_path,
      container_runtime          => $_runtime,
      container_runtime_endpoint => $_runtime_endpoint,
      hostname_override          => fact('networking.fqdn'),
      node_ip                    => $_node_ip,
  } + $arguments)

  $_sysconfig_path = pick($k8s::sysconfig_path, '/etc/sysconfig')
  file { "${_sysconfig_path}/kubelet":
    content => epp('k8s/sysconfig.epp', {
        comment               => 'Kubernetes Kubelet configuration',
        environment_variables => {
          'KUBELET_ARGS' => $_args.join(' '),
        },
    }),
    notify  => Service['kubelet'],
  }

  systemd::unit_file { 'kubelet.service':
    ensure  => $ensure,
    content => epp('k8s/service.epp', {
        name  => 'kubelet',
        desc  => 'Kubernetes Kubelet Server',
        doc   => 'https://github.com/GoogleCloudPlatform/kubernetes',
        needs => [$runtime_service,],
        bin   => 'kubelet',
    }),
    require => [
      File["${_sysconfig_path}/kubelet", '/etc/kubernetes/kubelet.conf'],
      User['kube'],
    ],
    notify  => Service['kubelet'],
  }
  service { 'kubelet':
    ensure => stdlib::ensure($ensure, 'service'),
    enable => true,
  }
  Package <| title == 'containernetworking-plugins' |> -> Service['kubelet']

  if $manage_firewall {
    firewalld_custom_service { 'kubelet':
      ensure      => $ensure,
      short       => 'kubelet',
      description => 'Kubernetes kubelet daemon',
      ports       => [
        {
          port     => '10250',
          protocol => 'tcp',
        },
      ],
    }
    firewalld_service { 'Allow k8s kubelet access':
      ensure  => $ensure,
      zone    => 'public',
      service => 'kubelet',
    }
  }
}
