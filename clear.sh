sudo systemctl stop amplet && \
sudo systemctl disable amplet && \
sudo rm -f /etc/systemd/system/amplet.service && \
sudo systemctl daemon-reload && \
sudo rm -f /usr/local/bin/amplet && \
sudo rm -rf /etc/amplet && \
echo "amplet removed"