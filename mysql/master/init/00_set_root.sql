-- Ensure root password is set early during init
ALTER USER 'root'@'localhost' IDENTIFIED BY 'rootpass';
FLUSH PRIVILEGES;

