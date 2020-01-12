from flask import Flask, render_template, request, redirect, url_for
import pymysql
import mysql.connector
import time
import logging

app = Flask(__name__)

print("Starting the application.")
print("Connecting to MySQL database at 172.26.1.2")

time.sleep(10)
conn = mysql.connector.connect(user='root', password='root', port='3306', database='login_data', host='172.26.1.2')
print("Connected to MySQL.")

@app.route("/")
def index():
	print("Loading index page.")
	return render_template("index.html", title="Welcome Page")

@app.route("/main")
def go_back():
	print("Going back to index page.")
	return render_template("index.html", title="Welcome Page")

@app.route("/register")
def register():
	print("Loading registration page.")
	return render_template("signup.html", title="Register Page")

@app.route("/signUp",methods=["POST"])
def signUp():
	print("Registration.")
	global username
	username = str(request.form["user"])
	password = str(request.form["password"])
	email = str(request.form["email"])
	cursor = conn.cursor()
	cursor.execute("INSERT INTO user (name,password,email)VALUES(%s,%s,%s)",(username,password,email))
	conn.commit()
	return redirect(url_for("login"))

@app.route("/login")
def login():
	print("Loading login page.")
	return render_template("login.html",title="Login Page")

@app.route("/checkUser",methods=["POST"])
def check():
	print("Checking login credentials.")
	error = ''
	username = str(request.form["user"])
	password = str(request.form["password"])
	cursor = conn.cursor()
	cursor.execute("SELECT name FROM user WHERE name ='"+username+"'")
	user = cursor.fetchone()
	try:
		if len(user) is 1:
			# return redirect(url_for("home"))
			return render_template("home.html", error=error, user=username)
	except TypeError:
		error = "Invalid credentials, try again..."
		print("Failed to login. Username = {0} Password = {1}".format(username, password))
		return render_template("login.html", error=error)
		# return redirect(url_for("login_retry"))

@app.route("/home")
def home():
	print("Loading home page.")
	return render_template("home.html", user=username)

@app.route("/about")
def about():
	print("Loading about page.")
	return render_template("about.html")

if __name__ == "__main__":
    app.run(host="0.0.0.0", debug=True)