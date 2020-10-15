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

* notes 01.12.2020
  * [jenkins-active-choices](#jenkins-active-choices)

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

### Linh tinh

- Nhân tiện Apple mới ra Iphone 12, các forums lại được dịp tranh cãi IOS vs Android, về công nghệ, giá cả bla bla... nhưng mình vẫn thích ai dùng hàng nấy thôi đừng nên dạy người khác cách tiêu tiền, tranh cãi mấy thứ đó trên mạng quá vô bổ.

- Lại nhớ cái clip khá hay của Steve Jobs lúc còn trẻ nói về thất bại của Xerox, đại khái là: 

  + Những người làm sản phẩm , gọi nôm na là "product people" giúp công ty tạo ra một sản phẩm tốt và hiểu rõ nhu cầu của người dùng, biết người dùng cần gì, luôn mang đến người dùng những thứ họ cần.

  + Khi công ty đã độc chiếm thị trường và không có đối thủ, thì những "product people" này thường không mang lại lợi ích nhiều cho công ty nữa, thay vào đó là những Sales, Marketing people.

  + Với Pepsico thì có thể là ổn, nhưng đối với những công ty công nghệ thì sao ? 

  + Tại sao chúng ta phải tạo ra một cái máy in tốt hơn khi mà chúng ta đã độc chiếm thị trường.

  + Các Sales, Marketing mang lại lợi nhuận lớn và dần lên nắm quyền điều hành (người sẽ không phân biệt được một good/bad product , không hiểu được ngừoi dùng cần gì mà chỉ quan tâm đến việc bán được thật nhiều sản phẩm ), các cổ đông lại thích điều đó.

  + "Product people" không còn được quyết định nhiều đến sản phẩm họ làm ra sẽ như thế nào nữa.

- link: https://www.youtube.com/watch?v=X3NASGb5m8s


### Jenkins-active-choices

  - Làm việc với Jenkins job yêu cầu truyền vào một params và phải dynamic thì plugin `Active Choices` cho phép bạn load một đoạn script để render các lựa chọn. 
  ( https://plugins.jenkins.io/uno-choice/ )

  - Use case: Một jenkins job truyền vào params là một directory và 1 file zip bất kì trong directory đó, lưu ý directory/zip file có thể thay đổi liên tục.

  - Phần `Active choices params` cho phép load một đoạn script (groovy) và return một list các lựa chọn, vì vậy ở đây có thể list các file và return nó về một list. 

  - Thêm nữa vì lúc thực thi script mặc định chạy trên master node nên mình phải thêm đoạn `ssh xxx` để list được các file trên agent node. ( build của mình schedule trên agent node chứ không phải master node ).
  
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