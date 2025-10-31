![Screenshot of a comment on a GitHub issue showing an image, added in the Markdown, of an Octocat smiling and raising a tentacle.](https://github.com/dj56959566/cftest/blob/main/photo_2025-10-30_16-03-29.jpg?raw=true)


把这个和刚刚那个放在一个文件一个文件夹里
三个文件

cfst 
cfst.sh
ip.txt

chmod +x cf.sh
chmod +x cfst

apt install curl wget jq bc -y

opkg update
opkg install curl jq wget bc -y


安装这些依赖


 

最后  直接运行 bash cf.sh

0 */6 * * * bash /tmp/cfs/cf.sh

每六小时跑一次

crontab -e
0 */6 * * * /bin/bash /opt/cf/cf.sh >/dev/null 2>&1

操作方法：

按 Ctrl + O （就是保存 Write Out）
👉 屏幕下方会出现提示：File Name to Write: /tmp/crontab.XXXX
直接按 Enter 确认保存。

然后按 Ctrl + X 退出。
