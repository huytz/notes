# notes
Technical notes


# Table of contents

* [Prometheus và k8s](#prometheus-và-k8s)
  
* [victoriametrics 1](#victoriametrics-1)

* [check số lượng vms trên gcp](#check-số-lượng-vms-trên-gcp)

* [script thêm device vpn p2p cho wireguard](#script-thêm-device-vpn-p2p-cho-wireguard)
  
* notes 15.10.2020
  * [jenkins](#jenkins)
  * [yaml](#yaml)
  * [daemon (pronounced dee-mon)](#daemon-pronounced-dee-mon)
  * [cgroups](#cgroups)
  * [Linh tinh](#linh-tinh)

* note 10.11.20202
  * [jenkins-pipeline](#jenkins-pipeline)

* notes 01.12.2020
  * [jenkins-active-choices](#jenkins-active-choices)

* notes 19.04.2021
  * [ansible-windows](#ansible-windows)

* notes 02.04.2023
  * Workload Identity trên GKE.
  * K8s Service ExternalName

## Prometheus và k8s

#### Với mình lý do chính dùng prometheus là để tận dụng Service Discovery(SD) của nó.

Instance prometheus chạy trong k8s sẽ dùng Pod SD để discover các pods và node.

ref: `https://prometheus.io/docs/prometheus/latest/configuration/configuration/#kubernetes_sd_config`

Thực ra thì các instance prometheus chạy ngoài k8s vẫn discover được nhưng theo mình thì không nên làm vậy, vì nó sẽ bị phụ thuộc vào network từ prometheus -> k8s API.

#### Để prometheus có để discover được Pods :

##### Instance prometheus:
  - Nếu instance đó không chạy trong k8s -> cần set thông tin về API-Server và cách để prometheus authen với k8s (basic authen/tls).
  - Nếu instance đã chạy trong k8s (recommand) thì bạn không cần làm gì cả, vì nó dùng Service Account của Pods để authen với API-Server.

##### Thêm job sau vào prometheus config 
    
    - job_name: kubernetes-pods
      honor_timestamps: true
      scrape_interval: 30s
      scrape_timeout: 10s
      metrics_path: /metrics
      scheme: http
      kubernetes_sd_configs:
      - role: pod
      relabel_configs:
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        separator: ;
        regex: "true"
        replacement: $1
        action: keep
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
        separator: ;
        regex: (.+)
        target_label: __metrics_path__
        replacement: $1
        action: replace
      - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
        separator: ;
        regex: ([^:]+)(?::\d+)?;(\d+)
        target_label: __address__
        replacement: $1:$2
        action: replace
      - separator: ;
        regex: __meta_kubernetes_pod_label_(.+)
        replacement: $1
        action: labelmap
      - source_labels: [__meta_kubernetes_namespace]
        separator: ;
        regex: (.*)
        target_label: kubernetes_namespace
        replacement: $1
        action: replace
      - source_labels: [__meta_kubernetes_pod_name]
        separator: ;
        regex: (.*)
        target_label: kubernetes_pod_name
        replacement: $1
        action: replace
    

#### Sau khi thêm vào thì các `Deployment` trong cluster chỉ cần set annontation cho pod spec:

`prometheus.io/scrape: "true"` -> notify prometheus cào metrics của pod.

`prometheus.io/path: "/metrics"` -> metrics path của pod, nếu pods có path khác /metrics thì mới cần set annontation này.

`prometheus.io/port: "8080"`   -> port của /metrics, có thể set nhiều port bằng dấu ',' .

```
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      workload.user.cattle.io/workloadselector: deployment-default-nginx
  strategy:
    type: RollingUpdate
  template:
    metadata:
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8080"
  ...
```

Vậy là các service được deploy lên k8s cluster sẽ được prometheus tự cào metrics về bằng job `kubernetes-pods`.

#### Flow của pod discovery cũng khá dễ hiểu, sẽ có một đọan code connect tới Kube-API server, sau đó watch các pods mới được tạo ra từ Kube-API và check annontation của Pod rồi update config cuả Prometheus.

ref: `https://github.com/prometheus/prometheus/tree/master/discovery/kubernetes`

## VictoriaMetrics #1

#### https://victoriametrics.github.io/

#### Tại sao phải cần một remote storage cho prometheus ?

Trong quá trình làm việc với prometheus thì một số team cần lưu metrics trong 1 - 2 tháng hoặc lâu hơn.

#### 1. Cách đầu tiên mình nghĩ là chỉ cần set retention lên 2 tháng là được.

Giả sử instance prometheus đang chạy có `875475` TSDB với retention là 5 ngày, cost 1x GB RAM. Thì việc nâng retention lên 2 tháng là gần như không thể vì sẽ cần 1 instance siêu to khổng lồ.

Chưa kể quá trình trình GC và load metrics của prometheus sẽ làm node tốn kha khá resource lúc query long range -> OOM killed.

```
/ $ ./prometheus/prometheus-2.13.0.linux-amd64/tsdb analyze prometheus/
Block ID: 01EAH2V9DMGK96ZNX6GS4T9DK7
Duration: 2h0m0s
`Series: 875475`
Label names: 354
Postings (unique label pairs): 38425
Postings entries (total label pairs): 11072071
```

#### 2. Feredate metrics cần lưu về một instance prometheus khác.

Đây cũng chỉ là một gỉai pháp tình thế, không khá hơn #1 là bao nhiêu.

Vì bạn sẽ phải scale dọc, đắp RAM và CPU vào chỉ để đảm bảo prometheus không bị OOM nữa.

#### 3. Giải pháp là remote write metrics vào một storage khác có khả năng HA và scale ngang được.

https://prometheus.io/docs/operating/integrations/#remote-endpoints-and-storage

Có rất nhều tools support làm remote storage cho Prometheus,mình chọn `VictoriaMetrics` chứ không phải những thứ fancy như Thanos, M3DB, Cortex... hoặc InfluxDB (con nhà giàu).


#### Lý do chọn VictoriaMetrics:

-  Ít component, architect dễ tiếp cận, concept đơn giản.

-  Có 2 mode là cluster và single.

-  Setup nhanh trên K8s với Helm Chart.

-  Prometheus cần ít RAM vì Retention và query đều ở VictoriaMetrics, Prometheus chỉ cào và gửi metrics đi.

-  Metrics retention 1 tháng hoặc có thể hơn.

-  Query performance, low cost so với các tool khác : Thanos, M3DB, Cortex...

Ref: https://github.com/VictoriaMetrics/VictoriaMetrics/wiki/CaseStudies#adidas


(...#2)

## Check số lượng VMs trên GCP

- requirements: prometheus instance `prometheus.xxxx.xxxx` đã config Service Discovery(SD) GCP. (https://prometheus.io/docs/prometheus/latest/configuration/configuration/#gce_sd_config)

  -> Nếu bạn đang chạy on-premise thì có thể dùng trick này để làm SD:  `https://github.com/linuxvn/about/blob/master/Notes-2019.md#nmap-for-prometheus`

- purpose: xem đã gần đạt threshold của CloudNAT.

- threshold hiện tại của CloudNAT (theo lý thuyết): xxx VMs

- current running VMs: (?) VMs

- command check:
  - `curl -sSL http://prometheus.xxxx.xxxx/api/v1/query\?query\=count\(up\=\=1\) | jq '.data.result[0].value[1]'`

## Script thêm device VPN p2p cho Wireguard.

- Yêu cầu package trước khi chạy script:
  + Cần 1 folder `device-template` tại thư mục `/etc/wireguard/clients/`
  + Chạy với quyền root.
  + `wireguard`.
  + `qrencode` để generate QR code.

- Script input : Tên thiết bị + IP sẽ cấp cho thiết bị.

- Script output:
  + QRcode để điện thoại có thể scan bằng camera.
  + Config device mới được lưu tại `/etc/wireguard/clients/${device}`.

- Ref: https://github.com/huytz/notes/tree/master/script/wireguad-add-device

## notes 15.10.2020

### Jenkins
- Làm việc với Jenkins ( groovy + scripted pipeline ) mới thấy được nó có thể làm mọi thứ trong DevOps.

  + Continuous Integration.
  + Continuous Delivery
  + Cron job.
  + Load test.
  + ...còn nhiều thứ mà mình chưa làm tới nào làm tới sẽ bổ sung

- Điểm mạnh của Jenkins là bạn có thể làm mọi thứ bạn muốn, dù bạn có để source của bạn ở đâu và mình cũng hạn chế dùng build-in CI của gitab,github,bitbucket... vì nếu bạn dùng mỗi service một loại hoặc mai mốt công ty bạn buồn buồn lại chuyển git repo, thì bạn lại phải setup CI/CD lại từ đầu, Jenkins (hoặc cái các tool 3rd) có thể giải quyết được vấn đề này, tất cả những gì bạn cần phải làm chỉ là add repo mới vào Jenkins. 

- Nhiều cty hiện nay vẫn dùng jenkins và dev groovy để exetend Jenkins và cung cấp PaaS , ví dụ như thằng này https://www.cloudbees.com/


### Yaml 
- Yaml là cách phổ biến để tương tác với k8s, nên các tool sinh ra cũng khá nhiều, nhưng cuối cùng thì output của bạn cũng chỉ là yaml và apply bằng `kubectl`.

  + Cách đơn giản nhất vẫn là (yaml) -> kubectl apply -f -> k8s.

  + Dùng kustomize patch yaml: (yaml) -> kustomize -> patch yaml -> k8s.

  + Cách "phúc" tạp : (yaml) + template -> helm -> go render template -> yaml -> k8s.

- Cách nào thì output cũng như nhau, cái mình quan tâm là việc operation đơn giản và lúc có lỗi thì debug nhanh, nên mình vẫn dùng kustomize.

### Daemon (pronounced dee-mon)
- Vô tình đọc được bài này khá hay nói về daemon trong unix, đọc xong có thể hiểu được một số cái basic:

  + Daemon vs Service trong unix.

  + Tại sao lại dùng 2 `fork()` lúc tạo ra một daemon.

- link: https://digitalbunker.dev/2020/09/03/understanding-daemons-unix/


### Cgroups 

- Một series về cgroups có 4 phần, giới thiệu về cgroups và cách implement nó vào OS.

- Làm việc nhiều với unix và k8s thì mình nghĩ series này là rất hữu ích, bạn sẽ hiểu được flow từ `k8s yaml -> container` khi bạn resquest/limit Memory, CPU cho một Deployment.

- link part one: https://www.redhat.com/sysadmin/cgroups-part-one


### jenkins-pipeline

  - Giống như hầu hết các tool CI, Jenkins cũng có "pipeline as code" định nghĩa trong Jenkinsfile.

  - Pipeline chia làm 2 loại cơ bản là `Scripted Pipeline` và `Declarative pipeline`, đều là DSL(domain specific language) nhưng khác biệt nhau về syntax cũng như cách implement, vậy tại sao lại phải chia ra làm 2 loại ?
  
    + Từ khi Jenkins ra đời thì groovy là ngôn ngữ chính để custom các job, stage theo ý của user -> Scripted Pipeline, bạn có thể viết hầu hết các function bằng groovy (programing style) và share chúng với Jenkins như một 3rd party code để Jenkins lấy ra và sử dụng.

    + Nhưng không phải ai cũng thích groovy và có thời gian để học hoặc ngồi viết lại các function nên mới sinh ra một "interface" đơn giản hơn để sử dụng groovy là `Declarative pipeline` ,các function đã có sẵn và bạn chỉ cần dùng nó. Các function này đi cùng với plugin, ví dụ cài đặt `Git` plugin thì bạn có thể dùng các function của Git (Checkout()...).

    + Điểm khác nhau giữa hai loại pipeline có thể tham khảo ở đây: https://www.jenkins.io/doc/book/pipeline/

- Tôi muốn implement Pipe line as code thì nên dùng loại nào ?

  Ý kiến cá nhân:
    
    +  Nên dùng cả 2 .
    +  `Declarative pipeline` khai báo các stage để tận dụng function có sẵn, pipeline syntax dễ hiểu và dùng block "script{}" để load các function từ Shared libraries ( https://www.jenkins.io/doc/book/pipeline/shared-libraries/#defining-shared-libraries - đây là cách để implement `Scripted pipeline`).
 
### Jenkins-active-choices

  - Làm việc với Jenkins job yêu cầu truyền vào một params và phải dynamic thì plugin `Active Choices` cho phép bạn load một đoạn script để render các lựa chọn. 
  ( https://plugins.jenkins.io/uno-choice/ )

  - Use case: Một jenkins job truyền vào params là một directory và 1 file zip bất kì trong directory đó, lưu ý directory/zip file có thể thay đổi liên tục.

  - Phần `Active choices params` cho phép load một đoạn script (groovy) và return một list các lựa chọn, vì vậy ở đây có thể list các file và return nó về một list. 

  - Thêm nữa lúc thực thi script mặc định chạy trên master node nên mình phải thêm đoạn `ssh xxx` để list được các file trên agent node. ( build của mình schedule trên agent node chứ không phải master node ).
  
  - Example: 
    ```
    // Function create a list from String
    def makeList(list) {
      List created = new ArrayList()
      list.eachLine { line ->
          created.add(line)
      }
      return created
    }

    // commandline list directory
    def cmd = "ssh agent-node ls /data/"

    // excute commnand
    def list = cmd.execute()

    // convert String to list
    def res = makeList(list.getText())

    return  res
    ```

  - Plugin này có thể load mọi thứ bằng groovy - khá đơn giản nhưng mà hiệu quả.
  - Bạn cũng có thể đưa nó vào `groovy shared lib` cho gọn hơn.

### ansible-windows

  - Ansible là một agentless configuration management, giúp quản lý config trên cả windows và linux.
  - Để ansible có thể thực thi được các kịch bản viết sẵn vào host thì chỉ cần một môi trường có thể chạy python.
  - Trên linux chuyện đó khá dễ khi chỉ cần connect được vào ssh vào execute python, nhưng trên windows thì không đơn giản vậy.
  - Trên windows có một component là Windows Remote Management (WinRM) giúp ansible có thể thực thi python.
    + Winrm sẽ lấy url `/wsman` trên IIS để ansible connect bằng http/https.
    + Port 3985 (non ssl) hoặc 3986 (ssl).
  - Setting cần chạy để ansible có thể connect vào windows server 2016:
  - #### Requirement :

    - Winrm. ( https://docs.microsoft.com/vi-vn/azure/monitoring/infrastructure-health/vmhealth-windows/winserver-svc-winrm )
    - Firewall for Winrm http - port 5985
    - Enable remote shell & allow shell execution.
    - Add trusted hosts to all (*)
    - `Local` user with Administrator group for ansible to excute the shell (can't run with DOMAIN user)

  - #### Run following script by shell (Run as Administrator)

    ```
        # setup windows hosts

        $TLS12Protocol = [System.Net.SecurityProtocolType] 'Ssl3 , Tls12'
        [System.Net.ServicePointManager]::SecurityProtocol = $TLS12Protocol

        $url = "https://raw.githubusercontent.com/ansible/ansible/devel/examples/scripts/ConfigureRemotingForAnsible.ps1"
        $file = "$env:temp\ConfigureRemotingForAnsible.ps1"

        (New-Object -TypeName System.Net.WebClient).DownloadFile($url, $file)

        powershell.exe -ExecutionPolicy ByPass -File $file

        # windows allow to execute script

        set-executionpolicy -executionpolicy remotesigned
        winrm quickconfig -q
        winrm set winrm/config/winrs '@{MaxMemoryPerShellMB="512"}'
        winrm set winrm/config '@{MaxTimeoutms="1800000"}'
        winrm set winrm/config/service '@{AllowUnencrypted="true"}'
        winrm set winrm/config/service/auth '@{Basic="true"}'

        # enable remoting shell

        Enable-PSRemoting –Force
  
        # add all trusted host

        Set-Item WSMan:\localhost\Client\TrustedHosts -Force -Value *

        # allow firewall for winrm HTTP port

        netsh advfirewall firewall add rule name="WinRM-HTTP" dir=in localport=5985 protocol=TCP action=allow

        # Create a user ansibe for playbook execution  (With Administrator permission). 

        net user ansible your-pass-word /ADD /FULLNAME:"Ansible" /PASSWORDCHG:NO /EXPIRES:NEVER

        net localgroup administrators ansible /add

    ```
  - Config Ansible :
    ```
      [all:vars]
      ansible_user=ansible
      ansible_password=your-pass-word
      ansible_port=5985 #winrm (non-ssl) port
      ansible_connection=winrm
      ansible_winrm_transport=basic
    ```
  - Theo config ở trên thì ansible sẽ connect vào windows host và execute python ở url: `http://ip-host:3985/wsman`
  
  ### notes 02.04.2023
  
  #### Workload Identity trên GKE.
    - Concept: https://cloud.google.com/kubernetes-engine/docs/concepts/workload-identity
    - Khi làm việc với K8s trên các Cloud bạn sẽ cần đến việc dùng Serivce account của Cloud từ Application, và cách đuợc các Cloud Provider khuyên dùng là Workload Identiy (GCP) hay OIDC (AWS).
    - Ý tưởng chung của 2 khái niệm này đều là quản lý được Application k8s đang được bind vào service account nào của Cloud.
    - Flow : Application <-> k8s servie account <-> binding <-> Cloud Service Account.
    - Tuy nhiên ở mỗi Cloud sẽ có design khác nhau ở việc binding này.
      - Ở GKE (Google Kubernetes Engine), khi bạn bật tính năng Workload Identity trên 1 cluster thì GCP sẽ tự động tạo một pool gọi là `workload identity pool` , với một tên mặc định là `PROJECT_ID.svc.id.goog`.
      - Nghĩa là dù bạn tạo bao nhiêu cluster trong một Project thì tất cả các cluster này đều dùng 1 pool lên là `PROJECT_ID.svc.id.goog`.
      - Ví dụ với 1 trường hợp cụ thể, mình có một cluster A với Service Account A' đã dùng workload identity và có quyền upload ảnh lên Google Object Storage X.
      - Sau đó mình tạo một Cluster B với các tham số:
          + Enable Worload Identity
          + Tạo một serice account A'.
      - Thì dĩ nhiên Application ở cluster B chỉ cần dùng đúng service account A' (giống namespace) thì có thể upload ảnh lên  Google Object Storage X mà không cần làm thêm actions gì.
      - Và ngay trong tài liệu của WI của Google đã nói: 
          + You can't change the name of the workload identity pool that GKE creates for your Google Cloud project.
          + To avoid untrusted access, place your clusters in separate projects to ensure that they get different workload identity pools, or ensure that the namespace names are distinct from each other to avoid a common member name.

      - Hãy xem một chút về cách hoạt động của AWS Open ID connect (OIDC) , có đề câp: Your cluster has an OpenID Connect (OIDC) issuer URL associated with it -> Nghĩa là mỗi Cluster sẽ dùng một ID riêng, chứ không dùng dung 1 pool như GCP.
      
      - Kết luận: Mỗi Cloud Provider có cách thiết kế khác nhau và tuỳ vào sự lựa chọn của người thiết kế:
        + Workload Identity của Google sẽ tiện hơn nếu bạn migrate Application giữa các cluster trong một Project vì bạn không cần làm gì trong việc sửa Workload Identity cả, chỉ cần dùng đúng service acccount và namespace.
        + OIDC của AWS lại an toàn hơn khi nó chia rõ ra từng cluster chứ không dùng chung một "pool" như Google.
        
   #### K8s Service ExternalName
      - K8s Service type ExternalName: https://kubernetes.io/docs/concepts/services-networking/service/#externalname
      - Use-case là khi mình muốn trỏ Backend của Kubernetes Ingress sang một Http server khác, bên ngoài cluster thì ExternalName là một giải pháp.
      - ```mermaid
          graph TD;
          Internet --> `example.com`;
          `example.com`--> `Path /` ;
          `example.com`--> `Path /devices`;
          `Path /` --> A ;
          `Path /devices` -> `External http server`;
        ```
      - Nhưng còn tuỳ thuộc vào endpoint `http server` đang là layer 4 hay layer 7:
       - Nếu http server đang ở dạng layer 4 , thì không cần thêm actions gì nữa.
       - Nhưng nếu http server đang ở Layer 7 Loadbanacer, thì sẽ có chút vấn đề ở đây: khi request đi từ Internet -> example.com thì trong Http request sẽ có header `Host: example.com` , và khi foward request sang external http server với domain khác ví dụ `x.com` thì request đó sẽ failed vì không có `Host: example.com` không có ở config trên proxy Layer 7.
       - Giải pháp ở đây là chỉ cần Http server `x.com` listen thêm domain `example.com`, bạn có thể tạo thêm 1 domain ở Http server.
       - Trong case của mình, `x.com` chạy trên K8s và dùng Kong Ingress Controller, nên việc này khá đơn giản, chỉ cần dùng `hostAlias` của KIC.
        ```
        apiVersion: networking.k8s.io/v1
        kind: Ingress
        metadata:
          name: ingress-x
          annotations:
            konghq.com/host-aliases: "example.com"
          spec:
        ingressClassName: gateway
        rules:
        - host: x.com
          http:
            paths:
            - backend:
                service:
                  name: x
                  port:
                    number: 8080
              path: /
              pathType: Prefix
        ```
        
