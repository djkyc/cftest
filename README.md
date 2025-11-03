![Screenshot of a comment on a GitHub issue showing an image, added in the Markdown, of an Octocat smiling and raising a tentacle.](https://github.com/dj56959566/cftest/blob/main/photo_2025-10-30_16-03-29.jpg?raw=true)


1.把这个和刚刚那个放在一个文件一个文件夹

三个文件

放到玩克云中  opt/cf/

cfst 

cfst.sh

ip.txt

2.给权限

chmod +x cf.sh

chmod +x cfst






3.安装这些依赖

opkg update

opkg install curl jq wget bc -y




4. 获取Cloudflare API Token

 1 访问 Cloudflare API Tokens (https://dash.cloudflare.com/profile/api-tokens)
   
 2 点击 "Create Token"
 
 3 选择 "Edit zone DNS" 模板
 
 4 在 "Zone Resources" 中选择 "Include All zones"
 
 5 点击 "Continue to summary" → "Create Token"
 
 6 复制生成的Token


cd opt/cf
 

5.最后  直接运行 bash cf.sh

![uAxv8koPchRfSY9Xe4j3lf2XIikKGdxx.webp](https://cdn.nodeimage.com/i/uAxv8koPchRfSY9Xe4j3lf2XIikKGdxx.webp)
