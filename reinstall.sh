sudo gem uninstall -aIx gollum
rake build
sudo gem install --no-ri --no-rdoc pkg/gollum*.gem